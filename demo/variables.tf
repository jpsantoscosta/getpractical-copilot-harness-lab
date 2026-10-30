variable "subscription_id" {
  description = "Subscription for the demo workload."
  type        = string
}

variable "location" {
  description = "Region for the demo workload."
  type        = string
  default     = "uksouth"
}

variable "owner" {
  description = "Value for the owner tag."
  type        = string
  default     = "getpractical"
}

variable "scenario" {
  description = "baseline is what you apply. risky is a bad change you only ever plan, to give the reviewer something to find."
  type        = string
  default     = "baseline"

  validation {
    condition     = contains(["baseline", "risky"], var.scenario)
    error_message = "scenario must be baseline or risky."
  }
}

variable "demo_api_key" {
  description = "Stand-in secret so the plan contains a sensitive variable. Not a real credential."
  type        = string
  default     = "demo-api-key-not-a-real-secret"
  sensitive   = true
}
