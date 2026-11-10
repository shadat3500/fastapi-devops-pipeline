# Extra variables used ONLY when testing against LocalStack (passed as a second -var-file).
# Intentionally empty: LocalStack serves the public SSM AMI parameter, so the same AMI
# lookup as real AWS is exercised. If your LocalStack version lacks it, set e.g.:
#   ami_id = "<an ID from: awslocal ec2 describe-images --query 'Images[].ImageId'>"
