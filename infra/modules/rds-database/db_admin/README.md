# DB Admin

Small Lambda function which configures an RDS database.

This is done as a Lambda (rather than with OpenTofu or something else) so that
we don't need to put the database instances in a subnet which has access to
the external internet. Instead, the Lambda has access from inside the AWS
network and does the small initial setup.
