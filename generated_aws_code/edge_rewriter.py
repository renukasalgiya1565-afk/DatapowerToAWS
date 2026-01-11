import json

def lambda_handler(event, context):
    """
    This Lambda@Edge function is triggered on an Origin Request.
    It checks for a specific path and method, and if it matches,
    it injects a SOAPAction header into the request before it's
    sent to the origin (API Gateway).
    """
    print(f"Received event: {json.dumps(event)}")
    
    request = event['Records'][0]['cf']['request']
    headers = request['headers']
    uri = request['uri']
    method = request['method']

    # Match the rule from DataPower's URLRewritePolicy
    # Match URI: ^/underwriting/quote/([A-Za-z0-9\-]+)$
    # Match Method: POST
    if method == 'POST' and uri.startswith('/underwriting/quote/'):
        print(f"Matched rule for {method} {uri}. Injecting SOAPAction header.")
        
        # Set the SOAPAction header
        headers['soapaction'] = [
            {
                'key': 'SOAPAction',
                'value': '"insurance.com"'
            }
        ]
    else:
        print(f"No rule matched for {method} {uri}. Passing through.")

    # Return the modified request to CloudFront
    return request
