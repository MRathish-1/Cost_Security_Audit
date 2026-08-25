# AWS-Project
For learning and building mini project focused AWS infra environment.

# Cost & Security Auditor

A single tool to automate audits across a **Multi OS (Windows and Linux)** EC2 fleet for **security exposure** and **cost waste** in one pass, no agents to install or bastion host and no standing cost.

## The problem

Security status and cost management are usually tracked separately: a security team checks for open remote-access ports and missing patches, while a cost team hunts for idle EBS volumes and orphaned Elastic IPs. In practice, both jobs come from the same root cause - resources nobody is actively managing and especially in SMB organisation where 1 - 2 member of infra support team taking care of all. This tasks can be automated - so this project checks both in one automated sweep, and does it across whichever OS the fleet actually runs, since real environments are rarely single-OS.

## Tech stack

AWS Systems Manager - Amazon S3 - AWS Lambda (Python) - Amazon SNS - IAM - PowerShell 7 / pwsh (AWS.Tools.EC2, AWS.Tools.S3)

Features
<img width="632" height="198" alt="features" src="https://github.com/user-attachments/assets/8c842f8c-5053-4520-9373-23c172cc286b" />

## Setup

1. **Launch EC2 instance(s)** on the free tier (t3.micro/t2.micro) - Windows Server 2022 and Ubuntu 22.04 LTS were used and tested here; other Linux distros (e.g. Amazon Linux) may need adjustments to the patch-log detection logic. Add Tag to instances e.g. 'Role=CSAManaged'.
2. **Install PowerShell 7 on each instance** via a user-data bootstrap script. This is required because '$IsWindows'/'$IsLinux' are PS6+ automatic variables and neither AMI ships PS7 by default.

   > **Note:** installing PS7 doesn't automatically gives the AWS Tools modules. Install **AWS.Tools.Installer** and the needed sub-modules (**AWS.Tools.S3**, **AWS.Tools.EC2**) explicitly under PS7's module path, and invoke the audit script via 'pwsh -File'/'pwsh -Command' rather than relying on SSM's default interpreter - **AWS-RunPowerShellScript** invokes Windows PowerShell 5.1 by default on Windows targets, which won't see modules installed under PS7.

3. **Attach the instance role** using the policy in 'iam/ec2-instance-role-policy.json' plus the AWS-managed 'AmazonSSMManagedInstanceCore' policy.
4. **Create the S3 bucket** (e.g. 'csa-reports-rm1') with a 'data/' prefix and '.json' as suffix.
5. **Deploy the Lambda** from 'lambda/csa_report_gen.py', set the 'SNS_TOPIC_ARN' environment variable, and attach the policy in 'iam/lambda-execution-role-policy.json'.
6. **Add an S3 trigger** on the Lambda for 'ObjectCreated' events under 'data/'.
7. **Create an SNS topic** and subscribe your email.
8. **Run the script** via SSM Run Command ('AWS-RunPowerShellScript', invoking 'pwsh' explicitly) targeting instances by tag.

## Sample report

<img width="1022" height="262" alt="SNS_email_linux" src="https://github.com/user-attachments/assets/84f300ca-2d3a-49df-bb5d-85ee81cd23d3" />

<img width="1015" height="367" alt="SNS_email_windows" src="https://github.com/user-attachments/assets/9ab2d40a-7f5f-4626-9dd6-b2952e55338f" />


## Testing

The remote-access exposure check was validated end-to-end with a live before/after test: opened SSH to `0.0.0.0/0` on a running Linux instance, confirmed the pipeline correctly flagged it CRITICAL via email with a 75/100 score, then reverted the rule and confirmed the score returned to 100/100 HEALTHY.

The remaining checks - patch staleness, privileged-account sprawl, endpoint protection, and all three cost checks - executed successfully against the live fleet and returned accurate baseline data (e.g. correctly identifying zero unattached volumes, zero idle EIPs, host firewall active), but weren't tested against a deliberately engineered failure state.
