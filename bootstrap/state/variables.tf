variable "project_id" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "location" {
  type    = string
  default = "ASIA-NORTHEAST1"
}

variable "state_admin_members" {
  type    = set(string)
  default = []
}

variable "state_writer_members" {
  type    = set(string)
  default = []
}
