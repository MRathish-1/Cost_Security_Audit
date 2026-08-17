# AWS-Project
For learning and building mini project focused AWS infra environment.

# Cost & Security Auditor

A single tool to automate audits across a **Multi OS (Windows and Linux)** EC2 fleet for **security exposure** and **cost waste** in one pass, no agents to install or bastion host and no standing cost.

## The problem

Security status and cost management are usually tracked separately: a security team checks for open remote-access ports and missing patches, while a cost team hunts for idle EBS volumes and orphaned Elastic IPs. In practice, both jobs come from the same root cause - resources nobody is actively managing and especially in SMB organisation where 1 - 2 member of infra support team taking care of all. This tasks can be automated - so this project checks both in one automated sweep, and does it across whichever OS the fleet actually runs, since real environments are rarely single-OS.

## Tech stack

AWS Systems Manager · Amazon S3 · AWS Lambda (Python) · Amazon SNS · Amazon EventBridge · IAM · PowerShell 7 / pwsh (AWS.Tools.EC2, AWS.Tools.S3)
