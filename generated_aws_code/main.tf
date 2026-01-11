provider "aws" {
  region = var.aws_region
}

# The Lambda@Edge function must be created in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

locals {
  api_name         = var.api_name
  transformer_lambda_name = "${local.api_name}-transformer"
  authorizer_lambda_name  = "${local.api_name}-authorizer"
  edge_rewriter_lambda_name = "${local.api_name}-edge-rewriter"
}

# --- Secrets for Credentials and URLs ---

resource "aws_secretsmanager_secret" "ldap_credentials" {
  name = "${local.api_name}/ldap-credentials"
  description = "Credentials for the LDAP service account."
}

resource "aws_secretsmanager_secret_version" "ldap_credentials_version" {
  secret_id     = aws_secretsmanager_secret.ldap_credentials.id
  secret_string = jsonencode({
    username = var.ldap_bind_dn
    password = var.ldap_bind_password
  })
}

resource "aws_secretsmanager_secret" "backend_url" {
  name = "${local.api_name}/backend-url"
  description = "URL for the backend SOAP service."
}

resource "aws_secretsmanager_secret_version" "backend_url_version" {
  secret_id     = aws_secretsmanager_secret.backend_url.id
  secret_string = jsonencode({
    url = var.backend_url
  })
}

# --- IAM Roles and Policies ---

# Role for the Transformer Lambda
resource "aws_iam_role" "transformer_lambda_role" {
  name               = "${local.transformer_lambda_name}-role"
  assume_role_policy = file("${path.module}/../iam/lambda_transformer_role.json")
}

resource "aws_iam_policy" "transformer_lambda_policy" {
  name   = "${local.transformer_lambda_name}-policy"
  policy = templatefile("${path.module}/../iam/lambda_transformer_policy.json", {
    backend_url_secret_arn = aws_secretsmanager_secret.backend_url.arn
  })
}

resource "aws_iam_role_policy_attachment" "transformer_lambda_attach" {
  role       = aws_iam_role.transformer_lambda_role.name
  policy_arn = aws_iam_policy.transformer_lambda_policy.arn
}

# Role for the Authorizer Lambda
resource "aws_iam_role" "authorizer_lambda_role" {
  name               = "${local.authorizer_lambda_name}-role"
  assume_role_policy = file("${path.module}/../iam/lambda_authorizer_role.json")
}

resource "aws_iam_policy" "authorizer_lambda_policy" {
  name   = "${local.authorizer_lambda_name}-policy"
  policy = templatefile("${path.module}/../iam/lambda_authorizer_policy.json", {
    ldap_credentials_secret_arn = aws_secretsmanager_secret.ldap_credentials.arn
  })
}

resource "aws_iam_role_policy_attachment" "authorizer_lambda_attach" {
  role       = aws_iam_role.authorizer_lambda_role.name
  policy_arn = aws_iam_policy.authorizer_lambda_policy.arn
}

# Role for the Lambda@Edge Rewriter
resource "aws_iam_role" "edge_rewriter_lambda_role" {
  provider           = aws.us_east_1
  name               = "${local.edge_rewriter_lambda_name}-role"
  assume_role_policy = file("${path.module}/../iam/lambda_edge_rewriter_role.json")
}

resource "aws_iam_policy" "edge_rewriter_lambda_policy" {
  provider = aws.us_east_1
  name     = "${local.edge_rewriter_lambda_name}-policy"
  policy   = file("${path.module}/../iam/lambda_edge_rewriter_policy.json")
}

resource "aws_iam_role_policy_attachment" "edge_rewriter_lambda_attach" {
  provider   = aws.us_east_1
  role       = aws_iam_role.edge_rewriter_lambda_role.name
  policy_arn = aws_iam_policy.edge_rewriter_lambda_policy.arn
}

# --- Lambda Functions and Layer ---

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../lambda_package.zip"
}

resource "aws_lambda_function" "transformer_lambda" {
  function_name    = local.transformer_lambda_name
  handler          = "transformer.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.transformer_lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      BACKEND_URL_SECRET_ARN = aws_secretsmanager_secret.backend_url.arn
    }
  }
}

resource "aws_lambda_function" "authorizer_lambda" {
  function_name    = local.authorizer_lambda_name
  handler          = "authorizer.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.authorizer_lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      LDAP_HOST            = var.ldap_host
      LDAP_PORT            = var.ldap_port
      LDAP_BASE_DN         = var.ldap_base_dn
      LDAP_GROUP_DN        = var.ldap_group_dn
      LDAP_BIND_SECRET_ARN = aws_secretsmanager_secret.ldap_credentials.arn
    }
  }
}

resource "aws_lambda_function" "edge_rewriter_lambda" {
  provider         = aws.us_east_1
  function_name    = local.edge_rewriter_lambda_name
  handler          = "edge_rewriter.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.edge_rewriter_lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  publish          = true # Required for Lambda@Edge
}

# --- API Gateway ---

resource "aws_api_gateway_rest_api" "underwriting_api" {
  name        = local.api_name
  description = "API for Underwriting service"
  body = templatefile("${path.module}/../openapi.yaml", {
    transformer_lambda_invoke_arn = aws_lambda_function.transformer_lambda.invoke_arn
    authorizer_lambda_invoke_arn = aws_lambda_function.authorizer_lambda.invoke_arn
  })
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# This resource is added to make the CloudFront rewrite functional but is NOT in the OpenAPI spec
resource "aws_api_gateway_resource" "quote_resource" {
  rest_api_id = aws_api_gateway_rest_api.underwriting_api.id
  parent_id   = aws_api_gateway_rest_api.underwriting_api.root_resource_id
  path_part   = "underwriting"
}
resource "aws_api_gateway_resource" "quote_sub_resource" {
  rest_api_id = aws_api_gateway_rest_api.underwriting_api.id
  parent_id   = aws_api_gateway_resource.quote_resource.id
  path_part   = "quote"
}
resource "aws_api_gateway_resource" "quote_id_resource" {
  rest_api_id = aws_api_gateway_rest_api.underwriting_api.id
  parent_id   = aws_api_gateway_resource.quote_sub_resource.id
  path_part   = "{id}"
}
resource "aws_api_gateway_method" "quote_post_method" {
  rest_api_id   = aws_api_gateway_rest_api.underwriting_api.id
  resource_id   = aws_api_gateway_resource.quote_id_resource.id
  http_method   = "POST"
  authorization = "NONE" # Auth can be added if needed, handled at CF edge or here
}
resource "aws_api_gateway_integration" "quote_post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.underwriting_api.id
  resource_id             = aws_api_gateway_resource.quote_id_resource.id
  http_method             = aws_api_gateway_method.quote_post_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.transformer_lambda.invoke_arn
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.underwriting_api.id
  # This depends on all methods/integrations implicitly through the 'body' of the rest_api resource
  # and explicitly on the quote method/integration
  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.underwriting_api.body))
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "api_gateway_logs" {
  name              = "/aws/api-gateway/${local.api_name}"
  retention_in_days = 7
}

resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.underwriting_api.id
  stage_name    = var.stage_name

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
    format          = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      path                    = "$context.path"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      authorizerPrincipalId   = "$context.authorizer.principalId"
    })
  }
}

resource "aws_lambda_permission" "api_gateway_permission_transformer" {
  statement_id  = "AllowAPIGatewayInvokeTransformer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transformer_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.underwriting_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_gateway_permission_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.underwriting_api.execution_arn}/*/*"
}

# --- CloudFront Distribution for URL Rewriting ---

resource "aws_s3_bucket" "cf_logs" {
  bucket = "${lower(local.api_name)}-cf-logs-${random_id.bucket_suffix.hex}"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_cloudfront_distribution" "api_cloudfront" {
  origin {
    domain_name = replace(aws_api_gateway_stage.api_stage.invoke_url, "/^(https:\/\/|http:\/\/)([^\/]+).*/", "$2")
    origin_path = "/${var.stage_name}"
    origin_id   = "api-gateway-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront for ${local.api_name}"
  default_root_object = ""

  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.cf_logs.bucket_domain_name
    prefix          = "cloudfront/"
  }

  # Default behavior for paths not matching the rewrite rule
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "api-gateway-origin"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type", "Host", "Origin"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  # Behavior for the URL rewrite path
  ordered_cache_behavior {
    path_pattern     = "/underwriting/quote/*"
    allowed_methods  = ["POST"]
    cached_methods   = []
    target_origin_id = "api-gateway-origin"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type", "Host", "Origin"]
      cookies {
        forward = "none"
      }
    }

    lambda_function_association {
      event_type   = "origin-request"
      lambda_arn   = aws_lambda_function.edge_rewriter_lambda.qualified_arn
      include_body = false
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
