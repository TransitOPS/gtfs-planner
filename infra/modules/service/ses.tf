data "aws_region" "current" {}

resource "aws_ses_domain_identity" "ses" {
  domain = var.domain
}

resource "aws_route53_record" "ses_verification" {
  zone_id = var.hosted_zone_id
  name    = "_amazonses.${var.domain}"
  type    = "TXT"
  ttl     = "600"
  records = [aws_ses_domain_identity.ses.verification_token]
}

resource "aws_ses_domain_dkim" "ses" {
  domain = aws_ses_domain_identity.ses.domain
}

resource "aws_route53_record" "ses_dkim_record" {
  count   = 3
  zone_id = var.hosted_zone_id
  name    = "${aws_ses_domain_dkim.ses.dkim_tokens[count.index]}._domainkey.${aws_ses_domain_identity.ses.domain}"
  type    = "CNAME"
  ttl     = "600"
  records = ["${aws_ses_domain_dkim.ses.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_ses_domain_mail_from" "ses" {
  domain           = aws_ses_domain_identity.ses.domain
  mail_from_domain = "mail.${aws_ses_domain_identity.ses.domain}"
}

resource "aws_route53_record" "mail_from_mx" {
  zone_id = var.hosted_zone_id
  name    = aws_ses_domain_mail_from.ses.mail_from_domain
  type    = "MX"
  ttl     = "600"
  records = ["10 feedback-smtp.${data.aws_region.current.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_txt" {
  zone_id = var.hosted_zone_id
  name    = aws_ses_domain_mail_from.ses.mail_from_domain
  type    = "TXT"
  ttl     = "600"
  records = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "dmarc" {
  zone_id = var.hosted_zone_id
  name    = "_dmarc.${aws_ses_domain_identity.ses.domain}"
  type    = "TXT"
  ttl     = "600"
  records = ["v=DMARC1;p=quarantine;rua=mailto:postmaster@transitops.co, mailto:dmarcreports@transitops.co; pct=1; adkim=r; aspf=r"]
}
