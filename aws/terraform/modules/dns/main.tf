# Route53 Hosted Zone
resource "aws_route53_zone" "main" {
  name = var.domain

  tags = { Name = "${var.prefix}-zone" }
}

# Wildcard DNS record pointing to ALB
# This is created by the ALB module after it creates the ALB
