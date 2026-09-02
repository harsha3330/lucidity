output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "backend_hcl" {
  description = "Contents for backend.hcl in 01-infra and 02-platform."
  value       = <<-EOT
    bucket = "${aws_s3_bucket.tfstate.bucket}"
    region = "${var.region}"
  EOT
}
