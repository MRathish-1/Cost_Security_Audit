"""
Cost & Security Auditor - Report Generator via Lambda (for manual-build)

Triggered by S3 ObjectCreated events on the data/ prefix. This script reads
each new findings JSON file (written by CSA_audit.ps1, from either a Windows or
Linux instance - same schema either way), scores it, and publishes a
consolidated report to an SNS topic (email subscription).

This script version reports findings only - see terraform-automated/lambda/ for
the version that also auto-remediates.

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

    if sec.get("RemoteAccessAllowedToInternet") is True:
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

    return max(score, 0), issues


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
        lines.append("")

    return "\n".join(lines)


def lambda_handler(event, context):
    reports = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = unquote_plus(record["s3"]["object"]["key"])

        obj = s3.get_object(Bucket=bucket, Key=key)
        findings = json.loads(obj["Body"].read())

        score, issues = score_findings(findings)
        reports.append(
            {
                "instance_id": findings.get("InstanceId"),
                "os": findings.get("OS", "Unknown"),
                "timestamp": findings.get("Timestamp"),
                "score": score,
                "issues": issues,
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
