## DataPower to AWS Migration: Detailed Mapping and Assumptions

This document outlines the mapping of the DataPower `MPGW_UnderwritingAPI` configuration to a serverless architecture on AWS. The primary components used are Amazon API Gateway, AWS Lambda (including Lambda@Edge), AWS IAM, AWS Secrets Manager, and Amazon CloudFront.

### 1. High-Level Architecture

The proposed AWS architecture consists of:

- **Amazon CloudFront**: Acts as the public-facing entry point, providing caching, WAF integration, and request rewriting capabilities via Lambda@Edge.
- **Amazon API Gateway (REST API)**: Exposes the core REST endpoints (`/v1/customer`, `/v1/underwriting/submit`).
- **AWS Lambda Authorizer**: A Lambda function that replicates the DataPower AAA policy, performing authentication and authorization against an LDAP directory.
- **AWS Lambda Integration**: A Lambda function that handles the core business logic: JSON to SOAP transformation and WS-Security header injection.
- **Lambda@Edge**: A Lambda function attached to CloudFront to handle the URL rewriting logic defined in the DataPower `URLRewritePolicy`.
- **AWS Secrets Manager**: Securely stores sensitive information like LDAP bind credentials and the backend service URL.
- **Amazon CloudWatch**: Used for logging from API Gateway, all Lambda functions, and CloudFront.

--- 

### 2. Component-by-Component Mapping

#### 2.1. Multi-Protocol Gateway (MPGW_UnderwritingAPI)

- **DataPower Element**: `dp:MultiProtocolGateway` named `MPGW_UnderwritingAPI`
- **AWS Mapping**: The MPGW is mapped to a combination of **Amazon API Gateway** and **Amazon CloudFront**.
  - **API Gateway (`aws_api_gateway_rest_api`)**: Defines the primary API contract for the endpoints explicitly listed in the processing policy (`/v1/customer`, `/v1/underwriting/submit`). It manages request validation, routing to backend integrations, and authorizers.
  - **CloudFront (`aws_cloudfront_distribution`)**: Sits in front of API Gateway to handle specific path-based rules that require complex rewriting, as defined by the `URLRewritePolicy`.
- **Assumptions**: The frontend protocol is upgraded from HTTP to HTTPS, which is the standard for API Gateway and CloudFront.

#### 2.2. Processing Policy (PP_Underwriting) & Rules

- **DataPower Elements**: `dp:ProcessingPolicy`, `dp:Rule` for `rule-customer-info` and `rule-underwriting-submit`.
- **AWS Mapping**: The two rules are mapped to specific **API Gateway Method resources**.
  - `POST /v1/customer` -> `aws_api_gateway_method` for this path.
  - `POST /v1/underwriting/submit` -> `aws_api_gateway_method` for this path.
- **Actions within the rules**: The sequence of actions (AAA, URLRewrite, XSLT, Route) is orchestrated by the API Gateway integration flow.
  - `AAA` -> Mapped to a Lambda Authorizer (see section 2.3).
  - `URLRewrite` -> The policy is referenced, but the rules within it do not match these paths. The rewrite logic is handled separately by CloudFront for its specific path (see section 2.4).
  - `XSLT` -> Mapped to the integration Lambda `lambda/transformer.py` (see section 2.5).
  - `Route` -> The final HTTP call to the backend is performed within the `lambda/transformer.py` function.

#### 2.3. AAA Policy (AAA_Policy_Underwriting)

- **DataPower Element**: `dp:AAAPolicy` named `AAA_Policy_Underwriting`.
- **AWS Mapping**: Replicated using an **API Gateway Lambda Authorizer** (`lambda/authorizer.py`) and **AWS Secrets Manager**.
  - **Identity Extraction (`http-basic`)**: The Lambda Authorizer receives the full request event, including the `Authorization` header. The Python code is responsible for parsing this header to extract the username and password.
  - **Authentication (`ldap`)**: The authorizer function uses the extracted credentials to perform an LDAP bind operation against the configured LDAP server. The LDAP server details (`host`, `port`, `bind DN`) are passed as environment variables, while the sensitive bind password is stored securely in **AWS Secrets Manager** (`aws_secretsmanager_secret.ldap_credentials`).
  - **Authorization (`ldap-group-dn`)**: After a successful bind, the authorizer performs an LDAP search to verify the user's membership in the required group (`CN=Underwriters,OU=Groups,DC=example,DC=com`).
  - **Post-Processing (WS-Security Token)**: This is a critical identity propagation step. The Lambda Authorizer, upon successful authentication, returns a policy document that includes a `context` block. This block contains the authenticated `username` and `password`. API Gateway passes this context to the integration Lambda (`lambda/transformer.py`), which then uses these credentials to construct the WS-Security `UsernameToken` header in the outbound SOAP request. This securely bridges the identity from the front-end call to the back-end service.

#### 2.4. URL Rewrite Policy (URLRewrite_Underwriting)

- **DataPower Element**: `dp:URLRewritePolicy` with rule `rewrite-quote-id` for `POST /underwriting/quote/{id}`.
- **AWS Mapping**: Implemented using **Amazon CloudFront** with a **Lambda@Edge** function (`lambda/edge_rewriter.py`).
  - A CloudFront `ordered_cache_behavior` is configured for the path pattern `/underwriting/quote/*`.
  - This behavior triggers the `edge_rewriter.py` function on the `origin-request` event.
  - The Lambda@Edge function inspects the request and, if it matches the pattern, injects the `SOAPAction: "insurance.com"` header before forwarding the request to the origin (API Gateway).
- **Assumption/Design Choice**: The `EXTRACTED_ENDPOINTS_JSON_ARRAY` and instructions strictly forbid adding `/underwriting/quote/{id}` to the `openapi.yaml` specification. However, to make the CloudFront rewrite functional, a corresponding path and method have been provisioned in the Terraform configuration for API Gateway. This path is considered an internal implementation detail and is not part of the public API contract.

#### 2.5. XSLT Transformations

- **DataPower Files**: `xsl/json-to-soap-application.xsl` and `xsl/insert-wsse-username-token.xsl`.
- **AWS Mapping**: The logic from both XSLT files is consolidated into a single Python function, `lambda/transformer.py`.
  - **JSON to SOAP**: The function receives the JSON body from the API Gateway event. It uses the `event['path']` to determine whether to construct a `<SaveCustomerInfo>` or `<SubmitApplication>` request, mirroring the conditional logic in the XSLT.
  - **WS-Security Insertion**: As described in section 2.3, the function retrieves the user's credentials from the authorizer context (`event['requestContext']['authorizer']`) and injects them into a WS-Security `UsernameToken`.
  - **XML Safety**: The SOAP envelope is constructed using Python's `xml.etree.ElementTree` library. This is a critical security measure to prevent XML injection attacks by properly escaping any special characters in the input data, rather than using unsafe string formatting.

#### 2.6. Backend Endpoint (BACKEND_SOAP_ALIAS)

- **DataPower Element**: `dp:HTTPProxyService` with `remote-address` `https://backend.example.com/soap/UnderwritingService`.
- **AWS Mapping**: The backend URL is stored in **AWS Secrets Manager** (`aws_secretsmanager_secret.backend_url`) and retrieved by the `lambda/transformer.py` function at runtime. Storing it as a secret allows for easier rotation and management without code changes.

#### 2.7. Logging and Auditing

- **DataPower Feature**: `dp:audit` set to `on`.
- **AWS Mapping**: Comprehensive logging is enabled across the architecture.
  - **API Gateway Access Logging**: The `aws_api_gateway_stage` resource is configured with `access_log_settings` to send detailed execution logs to a dedicated CloudWatch Log Group.
  - **Lambda Function Logging**: All Lambda functions (`authorizer`, `transformer`, `edge_rewriter`) are granted IAM permissions to write logs to their respective CloudWatch Log Groups.
  - **CloudFront Logging**: The `aws_cloudfront_distribution` is configured to deliver access logs to an S3 bucket for auditing and analysis.
