variable "aws_region" {
  default = "eu-central-1" # Frankfurt is usually good for Ukraine latency
}

variable "app_name" {
  default = "svitlo-monitor"
}

# We will pass these securely via command line or .tfvars, NOT hardcoded
variable "bot_token" {
  type      = string
  sensitive = true
}

variable "chat_id" {
  type = string
}

variable "proxy_url" {
  type      = string
  sensitive = true
  description = "Format: socks5://user:pass@YOUR_HOME_IP:PORT"
}

variable "monitor_config" {
  type = string
}