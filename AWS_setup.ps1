$bucketname = "malawi-mqp"
$username = "campbell-upload "
$userpolicyname = "allow_upload"
$functionname = "mqpfunction"
$region = "eu-central-1"
$accountnr = "446250998069"
$executionrole = "lambda-ex"

#create S3 bucket
aws s3 rm s3://$bucketname --recursive  
aws s3api delete-bucket --bucket $bucketname
aws iam delete-user-policy --user-name $username --policy-name $userpolicyname 

$json = aws iam list-access-keys --user-name test-upload | ConvertFrom-Json

aws iam delete-access-key --access-key-id $json.AccessKeyMetadata[0].AccessKeyId --user-name $username
aws iam delete-user --user-name $username


aws s3api create-bucket --bucket $bucketname --region $region --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api put-public-access-block --bucket $bucketname --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
aws s3api put-object --bucket $bucketname --key incoming/
aws s3api put-object --bucket $bucketname --key public/


((Get-Content -path bucket-policy.json -Raw) -replace '#bucketname#',$bucketname) | Set-Content -Path bucket-policy-temp.json
aws s3api put-bucket-policy --bucket $bucketname --policy file://bucket-policy-temp.json
Remove-Item bucket-policy-temp.json


# create user for S3 upload

aws iam create-user --user-name $username 
aws iam create-access-key --user-name $username

((Get-Content -path user-policy.json -Raw) -replace '#bucketname#',$bucketname) | Set-Content -Path user-policy-temp.json
aws iam put-user-policy --user-name $username --policy-name $userpolicyname --policy-document file://user-policy-temp.json
Remove-Item user-policy-temp.json



# login to ECR to upload docker image for lambda
aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $accountnr.dkr.ecr.$region.amazonaws.com
aws ecr create-repository --repository-name s3tomqp --image-scanning-configuration scanOnPush=true --image-tag-mutability MUTABLE

docker tag s3tomqp:latest $accountnr.dkr.ecr.eu-central-1.amazonaws.com/s3tomqp:latest
docker push $accountnr.dkr.ecr.eu-central-1.amazonaws.com/s3tomqp:latest

# create lambda role
aws iam create-role --role-name $executionrole --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name $executionrole --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam attach-role-policy --role-name $executionrole --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# create lambda function
aws lambda create-function --region $region --function-name $functionname  --package-type Image  --code ImageUri=$accountnr.dkr.ecr.eu-central-1.amazonaws.com/s3tomqp:latest --role arn:aws:iam::${accountnr}:role/$executionrole 

# set env variables
$INI = Get-Content .\publisher_lambda\env_aws -Raw | ConvertFrom-StringData
$temp=""
$INI.Keys | % { if (-Not ($_.StartsWith("AWS_"))) { $temp = $temp + $_+"="+$INI.Item($_)+"," } }

aws lambda update-function-configuration --function-name $functionname --environment "Variables={$temp}"

# allow S3 to access lambda function
aws lambda add-permission --function-name $functionname --action lambda:InvokeFunction --statement-id s3-account --principal s3.amazonaws.com --source-arn arn:aws:s3:::$bucketname --source-account $accountnr

# configure trigger 

$farn = "arn:aws:lambda:${region}:${accountnr}:function:${functionname}"
((Get-Content -path s3triggerlambdaconfig.json -Raw) -replace '#functionarn#',$farn) | Set-Content -Path s3triggerlambdaconfig-temp.json
aws s3api put-bucket-notification-configuration --bucket $bucketname --notification-configuration file://s3triggerlambdaconfig-temp.json
Remove-Item s3triggerlambdaconfig-temp.json

