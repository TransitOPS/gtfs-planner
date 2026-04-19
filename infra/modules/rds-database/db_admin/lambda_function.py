import json
import logging
import os
import boto3
from botocore.client import Config
from botocore.exceptions import ClientError
import pg8000.native
from pg8000.native import Error as DbError, identifier

app_username = "app"
extensions = ["citext"]

REGION_NAME = os.environ.get("AWS_REGION")

config = Config(connect_timeout=1, read_timeout=1, retries={"max_attempts": 0})
session = boto3.session.Session()
secretsmanager_client = session.client(
    service_name="secretsmanager", region_name=REGION_NAME, config=config
)

# Initialize the logger
logger = logging.getLogger()
logger.setLevel("INFO")


def lambda_handler(event, context):
    """
    Main Lambda entry point. Retrieves credentials and connects to RDS PostgreSQL
    using the pg8000 driver.
    """
    con = None
    try:
        db_host = os.environ["DB_HOST"]
        logger.debug(f"Trying to get secret value {os.environ['DB_PASSWORD_ARN']}...")
        secret = json.loads(
            secretsmanager_client.get_secret_value(
                SecretId=os.environ["DB_PASSWORD_ARN"]
            )["SecretString"]
        )
        db_username = secret["username"]
        db_password = secret["password"]
        db_name = os.environ["DB_NAME"]
        db_port = int(os.environ["DB_PORT"])

        logger.info(
            f"Attempting connection to {db_host}/{db_name} as user {db_username}..."
        )

        con = pg8000.native.Connection(
            db_username,
            password=db_password,
            host=db_host,
            port=db_port,
            database=db_name,
            ssl_context=True,
            # Aurora Serverless can take up to 15s to scale up from 0
            timeout=20,
        )

        [db_version] = con.run("SELECT version();")
        logger.info(f"Successfully connected. version={db_version[0]}")

        logger.info("Revoking access to public schema")
        con.run("REVOKE CREATE ON SCHEMA public FROM public")
        con.run(f"REVOKE ALL ON DATABASE {identifier(db_name)} FROM public")

        if (
            con.run(
                "SELECT usename FROM pg_user WHERE usename=:username",
                username=app_username,
            )
            == []
        ):
            logger.info(f"Creating user {app_username}")
            con.run(f"CREATE USER {identifier(app_username)}")

        logger.info(f"Granting IAM access to {app_username}")
        con.run(f"GRANT rds_iam TO {identifier(app_username)}")
        con.run(
            f"GRANT CONNECT ON DATABASE {identifier(db_name)} to {identifier(app_username)}"
        )
        con.run(f"GRANT CREATE ON SCHEMA public TO {identifier(app_username)}")
        for extension in extensions:
            logger.info(f"Creating {extension} extension")
            con.run(f"CREATE EXTENSION IF NOT EXISTS {identifier(extension)}")

        logger.info("All done!")
        return {
            "statusCode": 200,
        }

    except DbError as e:
        logger.error(f"Database connection error (pg8000): {e}")
        return {"statusCode": 500, "body": f"Database connection error: {e}"}
    except Exception as e:
        logger.error(f"An unexpected error occurred: {e}")
        return {"statusCode": 500, "body": f"An unexpected error occurred: {e}"}
    finally:
        # 4. Close the connection
        if con:
            con.close()
            logger.info("Database connection closed.")
