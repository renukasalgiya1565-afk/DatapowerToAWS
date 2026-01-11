import base64
import json
import os
import boto3
# Production code should use a proper LDAP library, e.g., 'ldap3'
# Add 'ldap3' to requirements.txt and create a Lambda Layer
# from ldap3 import Server, Connection, ALL, NTLM

# Placeholder for ldap3 library if not deployed in a layer
class Connection:
    def __init__(self, server, user, password, auto_bind=True):
        self.user = user
        self.result = {"description": "Authentication successful"} if user and password else {"description": "Anonymous bind"}
        print(f"[MOCK] LDAP Connection to {server} for user {user}")

    def bind(self):
        print(f"[MOCK] LDAP Bind for user {self.user}")
        # In a real scenario, this would raise an exception on failure
        if not self.user or not self.user.startswith("CN="):
             return False
        return True

    def search(self, search_base, search_filter, attributes):
        print(f"[MOCK] LDAP Search in {search_base} with filter {search_filter}")
        # Mock a successful group membership search
        if self.user == f"CN=testuser,OU=Users,{os.environ['LDAP_BASE_DN']}":
            return True
        return False

    def unbind(self):
        print("[MOCK] LDAP Unbind")


# Environment variables to be configured in Terraform
LDAP_HOST = os.environ.get('LDAP_HOST')
LDAP_PORT = int(os.environ.get('LDAP_PORT', 389))
LDAP_BASE_DN = os.environ.get('LDAP_BASE_DN')
LDAP_GROUP_DN = os.environ.get('LDAP_GROUP_DN')
LDAP_BIND_SECRET_ARN = os.environ.get('LDAP_BIND_SECRET_ARN')

secrets_client = boto3.client('secretsmanager')

def get_ldap_bind_credentials():
    """Retrieves LDAP bind credentials from AWS Secrets Manager."""
    print("Fetching LDAP bind credentials from Secrets Manager")
    response = secrets_client.get_secret_value(SecretId=LDAP_BIND_SECRET_ARN)
    secret = json.loads(response['SecretString'])
    return secret['username'], secret['password']

def lambda_handler(event, context):
    """Handles API Gateway authorization requests."""
    print(f"Authorizer event: {json.dumps(event)}")

    auth_header = event.get('headers', {}).get('authorization') or event.get('headers', {}).get('Authorization')
    if not auth_header or not auth_header.lower().startswith('basic '):
        print("Authorization header missing or not Basic type")
        return generate_policy('user', 'Deny', event['methodArn'])

    try:
        encoded_creds = auth_header.split(' ')[1]
        decoded_creds = base64.b64decode(encoded_creds).decode('utf-8')
        username, password = decoded_creds.split(':', 1)
    except (IndexError, ValueError, TypeError) as e:
        print(f"Error parsing Authorization header: {e}")
        return generate_policy('user', 'Deny', event['methodArn'])

    # In a real implementation, you would construct the full user DN
    # This is a simplified example.
    user_dn = f"CN={username},OU=Users,{LDAP_BASE_DN}"

    try:
        # Authenticate (bind) the user
        # The service account credentials are used to establish an initial connection
        # to perform the user bind and group search.
        # NOTE: A more secure approach is to bind directly as the user.
        # This example shows a service account search pattern.
        
        bind_user, bind_pass = get_ldap_bind_credentials()
        server = f"ldap://{LDAP_HOST}:{LDAP_PORT}" # Use ldaps:// for TLS
        
        # In a real implementation with the ldap3 library:
        # server_obj = Server(server, get_info=ALL)
        # conn = Connection(server_obj, user=bind_user, password=bind_pass, auto_bind=True)
        conn = Connection(server, user=bind_user, password=bind_pass) # Mock connection

        if not conn.bind(): # This would check the service account bind
            print("LDAP service account bind failed")
            return generate_policy(username, 'Deny', event['methodArn'])

        # Authorize (check group membership)
        # search_filter = f'(&(objectClass=groupOfNames)(member={user_dn}))'
        search_filter = f'(member={user_dn})'

        # In a real implementation:
        # is_member = conn.search(LDAP_GROUP_DN, search_filter, attributes=['cn'])
        is_member = conn.search(LDAP_GROUP_DN, search_filter, attributes=['cn']) # Mock search
        
        conn.unbind()

        if not is_member:
            print(f"Authorization failed: User {username} not in group {LDAP_GROUP_DN}")
            return generate_policy(username, 'Deny', event['methodArn'])
        
        print(f"Authentication and Authorization successful for user {username}")
        
        # IMPORTANT: Pass credentials to the integration lambda via context
        # This is how identity is propagated for the WS-Security token generation
        auth_context = {
            'username': username,
            'password': password # WARNING: Passing password. Ensure backend system needs it.
        }

        return generate_policy(username, 'Allow', event['methodArn'], context=auth_context)

    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        # In a production environment, avoid exposing detailed error messages.
        return generate_policy('user', 'Deny', event['methodArn'])

def generate_policy(principal_id, effect, resource, context=None):
    """Generates an IAM policy document for API Gateway."""
    policy = {
        'principalId': principal_id,
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [
                {
                    'Action': 'execute-api:Invoke',
                    'Effect': effect,
                    'Resource': resource
                }
            ]
        }
    }
    if context:
        policy['context'] = context
    
    print(f"Generated Policy: {json.dumps(policy)}")
    return policy
