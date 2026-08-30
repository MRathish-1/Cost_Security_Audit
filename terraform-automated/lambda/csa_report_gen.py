"""
Cost & Security Auditor - Report Generator via Lambda (auto-remediation build)

Triggered by S3 ObjectCreated events on the data/ prefix. This script reads
each new findings JSON file (written by SecurityCostAudit.ps1, from either
a Windows or Linux instance - same schema either way), scores it, auto-remediates
the open remote-access-port finding if present, and publishes a consolidated
report to an SNS topic (email subscription).

Auto-remediation runs immediately with no approval step: if a security
group tied to the instance allows the flagged port from 0.0.0.0/0, that
specific ingress rule is revoked before the report is sent. The report
shows what was found and what was fixed, so notification always follows
the action rather than gating it.

Environment variables:
    SNS_TOPIC_ARN  - ARN of the SNS topic to publish reports to
"""

import json
import os
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3

s3 = boto3.client("s3")
sns = boto3.client("sns")
ec2 = boto3.client("ec2")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def score_findings(findings):
    """Simple weighted scoring: 100 = perfect, deductions per issue found.
    Field names are unified across OS - the script sets the same keys
    whether the finding came from a Windows or Linux instance."""
    score = 100
    issues = []

    sec = findings.get("Security", {})
    cost = findings.get("Cost", {})
    port = sec.get("RemoteAccessPort", "remote access")

    open_to_internet = sec.get("RemoteAccessAllowedToInternet") is True
    if open_to_internet:
        score -= 25
        issues.append(f"CRITICAL: port {port} open to 0.0.0.0/0")
    if sec.get("PatchStatus") == "STALE":
        score -= 15
        issues.append(f"Patches stale ({sec.get('DaysSincePatch')} days since last update)")
    if sec.get("PrivilegedAccountSprawlFlag") is True:
        score -= 10
        issues.append(f"Privileged account sprawl: {sec.get('PrivilegedAccountCount')} accounts")
    if sec.get("EndpointProtectionActive") is False:
        score -= 15
        issues.append(f"Endpoint protection inactive ({sec.get('EndpointProtectionDetail', 'n/a')})")

    if cost.get("UnattachedVolumeCount", 0) > 0:
        score -= 5 * min(cost["UnattachedVolumeCount"], 4)
        issues.append(
            f"{cost['UnattachedVolumeCount']} unattached EBS volume(s) "
            f"({cost.get('UnattachedVolumeGB', 0)} GB still billing)"
        )
    if cost.get("IdleElasticIPCount", 0) > 0:
        score -= 5 * min(cost["IdleElasticIPCount"], 4)
        issues.append(f"{cost['IdleElasticIPCount']} idle Elastic IP(s) accruing hourly charges")
    if cost.get("StaleStoppedInstanceCount", 0) > 0:
        issues.append(
            f"{cost['StaleStoppedInstanceCount']} instance(s) stopped >7 days (EBS storage still billing)"
        )

    return max(score, 0), issues, open_to_internet, port


def get_instance_security_group_ids(instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    sg_ids = []
    for reservation in resp.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            for sg in instance.get("SecurityGroups", []):
                sg_ids.append(sg["GroupId"])
    return sg_ids


def is_safe_to_remediate(sg):
    """
    Guardrail on top of the IAM tag condition. Prevents from touching
    default security group under any circumstances, and requires
    the Role=CSAManaged tag to be present to limit the lambda task boundary
    """
    if sg.get("GroupName") == "default":
        print(f"Refusing to remediate {sg.get('GroupId')}: is the default security group.")
        return False

    tags = {t["Key"]: t["Value"] for t in sg.get("Tags", [])}
    if tags.get("Role") != "CSAManaged":
        print(f"Refusing to remediate {sg.get('GroupId')}: missing Role=CSAManaged tag.")
        return False

    return True


def revoke_open_port(instance_id, port):
    """
    Find and revoke any 0.0.0.0/0 ingress rule for the given port on
    every security group attached to the instance. Returns the list of
    security group IDs that were actually modified and get notified
    """
    remediated_sg_ids = []

    try:
        sg_ids = get_instance_security_group_ids(instance_id)
    except Exception as e:
        print(f"Could not look up security groups for {instance_id}: {e}")
        return remediated_sg_ids

    for sg_id in sg_ids:
        try:
            sg = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
        except Exception as e:
            print(f"Could not describe {sg_id}: {e}")
            continue

        if not is_safe_to_remediate(sg):
            continue

        for perm in sg.get("IpPermissions", []):
            from_port = perm.get("FromPort")
            to_port = perm.get("ToPort")
            if from_port is None or to_port is None or not (from_port <= port <= to_port):
                continue

            open_ranges = [r for r in perm.get("IpRanges", []) if r.get("CidrIp") == "0.0.0.0/0"]
            if not open_ranges:
                continue

            try:
                ec2.revoke_security_group_ingress(
                    GroupId=sg_id,
                    IpPermissions=[
                        {
                            "IpProtocol": perm["IpProtocol"],
                            "FromPort": from_port,
                            "ToPort": to_port,
                            "IpRanges": open_ranges,
                        }
                    ],
                )
                remediated_sg_ids.append(sg_id)
            except Exception as e:
                print(f"Failed to revoke rule on {sg_id}: {e}")

    return remediated_sg_ids


def build_report(reports):
    lines = [f"Cost & Security Auditor Report - {datetime.now(timezone.utc).isoformat()}", ""]

    for r in reports:
        if r["score"] >= 90:
            status = "HEALTHY"
        elif r["score"] >= 60:
            status = "NEEDS ATTENTION"
        else:
            status = "CRITICAL"

        lines.append(
            f"Instance: {r['instance_id']} ({r['os']})  |  Score: {r['score']}/100  |  {status}"
        )
        if r["issues"]:
            for issue in r["issues"]:
                lines.append(f"   - {issue}")
        else:
            lines.append("   - No issues found.")
        if r["remediated_sg_ids"]:
            sg_list = ", ".join(r["remediated_sg_ids"])
            lines.append("   Action taken:")
            lines.append(f"      - Revoked port {r['open_port']} rule (0.0.0.0/0) on {sg_list}")
        lines.append("")

    return "\n".join(lines)


def lambda_handler(event, context):
    reports = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = unquote_plus(record["s3"]["object"]["key"])

        obj = s3.get_object(Bucket=bucket, Key=key)
        findings = json.loads(obj["Body"].read())

        instance_id = findings.get("InstanceId")
        score, issues, open_to_internet, open_port = score_findings(findings)

        remediated_sg_ids = []
        if open_to_internet and instance_id:
            remediated_sg_ids = revoke_open_port(instance_id, open_port)

        reports.append(
            {
                "instance_id": instance_id,
                "os": findings.get("OS", "Unknown"),
                "timestamp": findings.get("Timestamp"),
                "score": score,
                "issues": issues,
                "open_port": open_port,
                "remediated_sg_ids": remediated_sg_ids,
            }
        )

    if not reports:
        return {"statusCode": 200, "body": "No new findings to process."}

    message = build_report(reports)

    if SNS_TOPIC_ARN:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="Cost & Security Auditor - Report",
            Message=message,
        )

    return {"statusCode": 200, "body": message}
