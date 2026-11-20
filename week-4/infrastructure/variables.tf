# Define the QuickCart project name.
variable "project_name" {
  description = "Name of the QuickCart project" # Explain the variable.
  type        = string                          # Store the name as text.
  default     = "quickcart-order-processing"    # Set the project name.
}

# Define the deployment environment.
variable "environment" {
  description = "Deployment environment" # Explain the variable.
  type        = string                   # Store the environment as text.
  default     = "dev"                    # Use the development environment.
}
