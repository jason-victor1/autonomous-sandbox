import os
import sys
import boto3
from botocore.exceptions import ClientError


def main() -> None:
    bucket_name = os.getenv("MODEL_BUCKET_NAME")
    region = os.getenv("AWS_REGION", "us-east-1")

    print("[*] Initializing isolated Agent Worker runtime...")
    print(f"[*] Bound S3 Model Perimeter: {bucket_name}")

    if not bucket_name:
        print("[!] FATAL: MODEL_BUCKET_NAME environment variable not set.")
        sys.exit(1)

    s3_client = boto3.client("s3", region_name=region)

    try:
        # Verify access to private data perimeter
        response = s3_client.list_objects_v2(Bucket=bucket_name, MaxKeys=5)
        keys = [item["Key"] for item in response.get("Contents", [])]
        print(
            f"[+] Successfully verified S3 PrivateLink connection. Stored artifacts: {keys}")
    except ClientError as e:
        print(
            f"[!] Access Denied or Egress Blocked: {e.response['Error']['Message']}")
        sys.exit(1)


if __name__ == "__main__":
    main()
