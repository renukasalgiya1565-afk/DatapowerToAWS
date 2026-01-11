import json
import os
import requests
import xml.etree.ElementTree as ET
from xml.dom import minidom
import boto3

# Environment variables to be configured in Terraform
BACKEND_URL_SECRET_ARN = os.environ.get('BACKEND_URL_SECRET_ARN')

# Initialize boto3 client outside the handler for reuse
secrets_client = boto3.client('secretsmanager')

def get_backend_url():
    """Retrieves backend URL from AWS Secrets Manager."""
    print("Fetching backend URL from Secrets Manager")
    response = secrets_client.get_secret_value(SecretId=BACKEND_URL_SECRET_ARN)
    secret = json.loads(response['SecretString'])
    return secret['url']

BACKEND_URL = get_backend_url()

# --- Safe XML Construction Helpers ---

def build_soap_envelope(username, password, soap_body_element):
    """Constructs a complete SOAP envelope with a WS-Security header securely."""
    # XML Namespaces
    NS_SOAP = "http://schemas.xmlsoap.org/soap/envelope/"
    NS_WSSE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    NS_WSU = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"

    # Register namespaces to get clean prefixes (e.g., <soap:Envelope>)
    ET.register_namespace('soap', NS_SOAP)
    ET.register_namespace('wsse', NS_WSSE)
    ET.register_namespace('wsu', NS_WSU)

    # Create SOAP Envelope
    envelope = ET.Element(f"{{{NS_SOAP}}}Envelope")
    
    # Create SOAP Header with WS-Security UsernameToken
    header = ET.SubElement(envelope, f"{{{NS_SOAP}}}Header")
    security = ET.SubElement(header, f"{{{NS_WSSE}}}Security")
    username_token = ET.SubElement(security, f"{{{NS_WSSE}}}UsernameToken", {f"{{{NS_WSU}}}Id": "UsernameToken-1"})
    
    # Safely add username and password
    wsse_user = ET.SubElement(username_token, f"{{{NS_WSSE}}}Username")
    wsse_user.text = username
    
    wsse_pass = ET.SubElement(username_token, f"{{{NS_WSSE}}}Password", {
        "Type": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText"
    })
    wsse_pass.text = password

    # Create SOAP Body and append the provided body element
    body = ET.SubElement(envelope, f"{{{NS_SOAP}}}Body")
    body.append(soap_body_element)
    
    # Convert ElementTree object to a string
    # Using minidom for pretty printing, which is optional
    rough_string = ET.tostring(envelope, 'utf-8')
    reparsed = minidom.parseString(rough_string)
    return reparsed.toprettyxml(indent="  ", encoding='utf-8')

def create_operation_payload(root_element_name, data):
    """Creates the main SOAP operation payload from a dictionary."""
    root = ET.Element(root_element_name)
    # Recursively build XML from the input JSON data
    # This matches the generic copy behavior in the XSLT
    for key, value in data.items():
        if isinstance(value, dict):
            parent_element = ET.SubElement(root, key.capitalize()) # e.g., <Applicant>
            for sub_key, sub_value in value.items():
                 if isinstance(sub_value, dict):
                    child_element = ET.SubElement(parent_element, sub_key.capitalize()) # e.g., <Customer>
                    for item_key, item_value in sub_value.items():
                        elem = ET.SubElement(child_element, item_key)
                        elem.text = str(item_value)
    return root

# --- Lambda Handler ---

def lambda_handler(event, context):
    """Main Lambda handler for transforming JSON to SOAP and calling the backend."""
    print(f"Received event: {json.dumps(event)}")

    try:
        # 1. Get identity from Lambda Authorizer context
        authorizer_context = event.get('requestContext', {}).get('authorizer', {})
        username = authorizer_context.get('username')
        password = authorizer_context.get('password')

        if not username or not password:
            return {'statusCode': 401, 'body': 'Unauthorized: Missing credentials from authorizer.'}

        # 2. Get incoming JSON body
        body = json.loads(event.get('body', '{}'))

        # 3. Determine SOAP operation based on request path (replicating XSLT logic)
        request_path = event.get('path', '')
        soap_action_header = {}
        if '/v1/underwriting/submit' in request_path:
            operation_name = 'SubmitApplication'
            payload_element = create_operation_payload(operation_name, body)
        elif '/v1/customer' in request_path:
            operation_name = 'SaveCustomerInfo'
            payload_element = create_operation_payload(operation_name, body)
        # This handles the rewritten path from CloudFront
        elif '/underwriting/quote' in request_path:
             operation_name = 'GetQuote' # Assumed operation name
             payload_element = create_operation_payload(operation_name, body)
             # SOAPAction is injected by Lambda@Edge, but we can set it here too if needed
             # soap_action_header = {'SOAPAction': '"insurance.com"'}
        else:
            return {'statusCode': 400, 'body': f'Bad Request: Unknown path {request_path}'}

        # 4. Build the full SOAP envelope with WS-Security header
        soap_request_body = build_soap_envelope(username, password, payload_element)
        print(f"Generated SOAP Request:\n{soap_request_body.decode('utf-8')}")

        # 5. Call the backend SOAP service
        headers = {
            'Content-Type': 'text/xml; charset=utf-8',
            **soap_action_header # Add SOAPAction if defined
        }

        print(f"Sending request to backend: {BACKEND_URL}")
        response = requests.post(BACKEND_URL, data=soap_request_body, headers=headers, timeout=10)
        response.raise_for_status() # Raise an exception for bad status codes (4xx or 5xx)

        print(f"Received backend response ({response.status_code}):\n{response.text}")
        
        # 6. Return response to API Gateway
        return {
            'statusCode': response.status_code,
            'headers': {
                'Content-Type': 'application/xml'
            },
            'body': response.text
        }

    except requests.exceptions.RequestException as e:
        print(f"Error calling backend service: {e}")
        return {'statusCode': 503, 'body': 'Service Unavailable: Could not connect to backend.'}
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return {'statusCode': 500, 'body': 'Internal Server Error'}
