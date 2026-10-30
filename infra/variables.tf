variable "subscription_id" {
  description = "Subscription that hosts the lab."
  type        = string
}

variable "location" {
  description = "Azure region. Must be one of the regions that support the Microsoft Copilot harness (preview)."
  type        = string
  default     = "uksouth"

  validation {
    condition = contains([
      "australiaeast", "canadacentral", "centralus", "germanywestcentral", "japaneast",
      "swedencentral", "uksouth", "westeurope", "westus",
    ], var.location)
    error_message = "The Copilot harness preview only runs in Australia East, Canada Central, Central US, Germany West Central, Japan East, Sweden Central, UK South, West Europe and West US."
  }
}

variable "owner" {
  description = "Value for the owner tag."
  type        = string
  default     = "getpractical"
}

variable "model_capacity" {
  description = "gpt-5.4-mini Global Standard capacity in thousands of tokens per minute."
  type        = number
  default     = 100
}

variable "egress_mode" {
  description = "Egress guardrail mode for the harness sandbox: Enforced blocks, Audit only logs."
  type        = string
  default     = "Enforced"

  validation {
    condition     = contains(["Enforced", "Audit"], var.egress_mode)
    error_message = "egress_mode must be Enforced or Audit."
  }
}

variable "egress_allowed_hosts" {
  description = "Hosts (DNS wildcard syntax, e.g. *.contoso.com) the harness sandbox may call directly. Everything else is denied."
  type        = list(string)
  default     = []
}
