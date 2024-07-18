module "labels" {
  source      = "git::https://github.com/yadavprakash/terraform-aws-labels.git?ref=v1.0.0"
  name        = var.name
  environment = var.environment
  managedby   = var.managedby
  label_order = var.label_order
  repository  = var.repository
}

resource "random_id" "password" {
  count       = var.enabled ? 1 : 0
  byte_length = 20
}

locals {

  identifier_prefix    = var.use_identifier_prefix ? "${var.identifier}-" : null
  db_subnet_group_name = var.enabled_db_subnet_group ? join("", aws_db_subnet_group.this[*].id) : var.db_subnet_group_name

  username       = var.replicate_source_db != null ? null : var.username
  password       = var.password == "" ? join("", random_id.password[*].b64_url) : var.password
  engine         = var.replicate_source_db != null ? null : var.engine
  engine_version = var.replicate_source_db != null ? null : var.engine_version
  //  name_prefix = var.use_name_prefix ? "${var.name}-" : null
  description = coalesce(var.option_group_description, format("%s option group", var.name))
}

resource "random_id" "snapshot_identifier" {
  count = var.enabled && !var.skip_final_snapshot ? 1 : 0

  keepers = {
    id = var.identifier
  }

  byte_length = 4
}

resource "aws_db_subnet_group" "this" {
  count       = var.enabled && var.enabled_db_subnet_group ? 1 : 0
  name        = module.labels.id
  description = local.description
  subnet_ids  = var.subnet_ids
  tags = merge(
    module.labels.tags,
    var.db_subnet_group_tags
  )
}

resource "aws_db_parameter_group" "this" {
  count = var.enabled ? 1 : 0

  name        = module.labels.id
  description = local.description
  family      = var.family
  dynamic "parameter" {
    for_each = var.parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = lookup(parameter.value, "apply_method", null)
    }
  }
  tags = merge(
    module.labels.tags,
    var.db_parameter_group_tags,
    {
      "Name" = format("%s%sparameter", module.labels.id, var.delimiter)
    }
  )
  lifecycle {
    create_before_destroy = true
  }
}


resource "aws_db_option_group" "this" {
  count = var.enabled ? 1 : 0

  name                     = module.labels.id
  option_group_description = local.description
  engine_name              = var.engine_name
  major_engine_version     = var.major_engine_version
  dynamic "option" {
    for_each = var.options
    content {
      option_name                    = option.value.option_name
      port                           = lookup(option.value, "port", null)
      version                        = lookup(option.value, "version", null)
      db_security_group_memberships  = lookup(option.value, "db_security_group_memberships", null)
      vpc_security_group_memberships = lookup(option.value, "vpc_security_group_memberships", null)
      dynamic "option_settings" {
        for_each = lookup(option.value, "option_settings", [])
        content {
          name  = lookup(option_settings.value, "name", null)
          value = lookup(option_settings.value, "value", null)
        }
      }
    }
  }

  tags = merge(
    module.labels.tags,
    var.db_option_group_tags,
    {
      "Name" = format("%s%soption-group", module.labels.id, var.delimiter)
    }
  )

  timeouts {
    delete = lookup(var.timeouts, "delete", null)
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = toset([for log in var.enabled_cloudwatch_logs_exports : log if var.enabled && var.enabled_cloudwatch_log_group && !var.use_identifier_prefix])

  name              = "/aws/rds/instance/${module.labels.id}/${each.value}"
  retention_in_days = var.cloudwatch_log_group_retention_in_days
  kms_key_id        = var.kms_key_id == "" ? join("", aws_kms_key.default[*].arn) : var.kms_key_id

  tags = merge(
    module.labels.tags,
    var.cloudwatch_log_group_tags
  )
}

data "aws_iam_policy_document" "enhanced_monitoring" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "enhanced_monitoring" {
  count = var.enabled_monitoring_role ? 1 : 0

  name                 = module.labels.id
  assume_role_policy   = data.aws_iam_policy_document.enhanced_monitoring.json
  description          = var.monitoring_role_description
  permissions_boundary = var.monitoring_role_permissions_boundary

  tags = merge(
    {
      "Name" = format("%s", var.monitoring_role_name)
    },
    module.labels.tags,
    var.mysql_iam_role_tags
  )
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  count = var.enabled_monitoring_role ? 1 : 0

  role       = aws_iam_role.enhanced_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_security_group" "default" {
  count = var.enable_security_group && length(var.sg_ids) < 1 ? 1 : 0

  name        = format("%s-sg-%s", module.labels.id, local.engine)
  vpc_id      = var.vpc_id
  description = var.sg_description
  tags        = module.labels.tags
  lifecycle {
    create_before_destroy = true
  }
}

#tfsec:ignore:aws-ec2-no-public-egress-sgr
resource "aws_security_group_rule" "egress" {
  count = (var.enable_security_group == true && length(var.sg_ids) < 1 && var.is_external == false && var.egress_rule == true) ? 1 : 0

  description       = var.sg_egress_description
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join("", aws_security_group.default[*].id)
}

#tfsec:ignore:aws-ec2-no-public-egress-sgr
resource "aws_security_group_rule" "egress_ipv6" {
  count = (var.enable_security_group == true && length(var.sg_ids) < 1 && var.is_external == false) && var.egress_rule == true ? 1 : 0

  description       = var.sg_egress_ipv6_description
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = join("", aws_security_group.default[*].id)
}

resource "aws_security_group_rule" "ingress" {
  count = length(var.allowed_ip) > 0 == true && length(var.sg_ids) < 1 ? length(compact(var.allowed_ports)) : 0

  description       = var.sg_ingress_description
  type              = "ingress"
  from_port         = element(var.allowed_ports, count.index)
  to_port           = element(var.allowed_ports, count.index)
  protocol          = var.protocol
  cidr_blocks       = var.allowed_ip
  security_group_id = join("", aws_security_group.default[*].id)
}

resource "aws_kms_key" "default" {
  count = var.kms_key_enabled && var.kms_key_id == "" ? 1 : 0

  description              = var.kms_description
  key_usage                = var.key_usage
  deletion_window_in_days  = var.deletion_window_in_days
  is_enabled               = var.is_enabled
  enable_key_rotation      = var.enable_key_rotation
  customer_master_key_spec = var.customer_master_key_spec
  policy                   = data.aws_iam_policy_document.default.json
  multi_region             = var.kms_multi_region
  tags                     = module.labels.tags
}

resource "aws_kms_alias" "default" {
  count = var.kms_key_enabled && var.kms_key_id == "" ? 1 : 0

  name          = coalesce(var.alias, format("alias/%v", module.labels.id))
  target_key_id = var.kms_key_id == "" ? join("", aws_kms_key.default[*].id) : var.kms_key_id
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_iam_policy_document" "default" {
  version = "2012-10-17"
  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"
    principals {
      type = "AWS"
      identifiers = [
        format(
          "arn:%s:iam::%s:root",
          join("", data.aws_partition.current[*].partition),
          data.aws_caller_identity.current.account_id
        )
      ]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_db_instance" "this" {
  count             = var.enabled && var.enabled_read_replica ? 1 : 0
  identifier        = module.labels.id
  identifier_prefix = local.identifier_prefix

  engine            = local.engine
  engine_version    = local.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = var.storage_type
  storage_encrypted = var.storage_encrypted
  kms_key_id        = var.kms_key_id == "" ? join("", aws_kms_key.default[*].arn) : var.kms_key_id
  license_model     = var.license_model

  db_name                             = var.db_name
  username                            = local.username
  password                            = local.password
  port                                = var.port
  domain                              = var.domain
  domain_iam_role_name                = var.domain_iam_role_name
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  custom_iam_instance_profile         = var.custom_iam_instance_profile


  vpc_security_group_ids = length(var.sg_ids) < 1 ? aws_security_group.default[*].id : var.sg_ids
  db_subnet_group_name   = local.db_subnet_group_name
  parameter_group_name   = join("", aws_db_parameter_group.this[*].name)
  option_group_name      = join("", aws_db_option_group.this[*].name)
  network_type           = var.network_type

  availability_zone   = var.availability_zone
  multi_az            = var.multi_az
  iops                = var.iops
  storage_throughput  = var.storage_throughput
  publicly_accessible = var.publicly_accessible
  ca_cert_identifier  = var.ca_cert_identifier

  allow_major_version_upgrade = var.allow_major_version_upgrade
  auto_minor_version_upgrade  = var.auto_minor_version_upgrade
  apply_immediately           = var.apply_immediately
  maintenance_window          = var.maintenance_window


  dynamic "blue_green_update" {
    for_each = length(var.blue_green_update) > 0 ? [var.blue_green_update] : []

    content {
      enabled = try(blue_green_update.value.enabled, null)
    }
  }

  snapshot_identifier       = var.snapshot_identifier
  copy_tags_to_snapshot     = var.copy_tags_to_snapshot
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = module.labels.id

  #tfsec:ignore:aws-rds-enable-performance-insights
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.performance_insights_kms_key_id : null

  replica_mode            = var.replica_mode
  backup_retention_period = length(var.blue_green_update) > 0 ? coalesce(var.backup_retention_period, 1) : var.backup_retention_period
  backup_window           = var.backup_window
  max_allocated_storage   = var.max_allocated_storage
  monitoring_interval     = var.monitoring_interval
  monitoring_role_arn     = join("", aws_iam_role.enhanced_monitoring[*].arn)

  character_set_name              = var.character_set_name
  timezone                        = var.timezone
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  deletion_protection      = var.deletion_protection
  delete_automated_backups = var.delete_automated_backups

  dynamic "restore_to_point_in_time" {
    for_each = var.restore_to_point_in_time != null ? [var.restore_to_point_in_time] : []

    content {
      restore_time                             = lookup(restore_to_point_in_time.value, "restore_time", null)
      source_db_instance_automated_backups_arn = lookup(restore_to_point_in_time.value, "source_db_instance_automated_backups_arn", null)
      source_db_instance_identifier            = lookup(restore_to_point_in_time.value, "source_db_instance_identifier", null)
      source_dbi_resource_id                   = lookup(restore_to_point_in_time.value, "source_dbi_resource_id", null)
      use_latest_restorable_time               = lookup(restore_to_point_in_time.value, "use_latest_restorable_time", null)
    }
  }

  dynamic "s3_import" {
    for_each = var.s3_import != null ? [var.s3_import] : []

    content {
      source_engine         = "mysql"
      source_engine_version = s3_import.value.source_engine_version
      bucket_name           = s3_import.value.bucket_name
      bucket_prefix         = lookup(s3_import.value, "bucket_prefix", null)
      ingestion_role        = s3_import.value.ingestion_role
    }
  }

  tags = merge(
    module.labels.tags,
    var.db_instance_this_tags
  )

  depends_on = [aws_cloudwatch_log_group.this]

  timeouts {
    create = lookup(var.timeouts, "create", null)
    delete = lookup(var.timeouts, "delete", null)
    update = lookup(var.timeouts, "update", null)
  }

}

resource "aws_db_instance" "read" {
  count = var.enabled && var.enabled_read_replica && var.enabled_replica ? 1 : 0

  identifier        = format("%s-replica", module.labels.id)
  identifier_prefix = local.identifier_prefix

  engine            = null
  engine_version    = null
  instance_class    = var.replica_instance_class
  allocated_storage = var.allocated_storage
  storage_type      = var.storage_type
  storage_encrypted = var.storage_encrypted
  kms_key_id        = var.kms_key_id == "" ? join("", aws_kms_key.default[*].arn) : var.kms_key_id
  license_model     = var.license_model

  db_name                             = null
  username                            = null
  password                            = local.password
  port                                = var.port
  domain                              = var.domain
  domain_iam_role_name                = var.domain_iam_role_name
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  custom_iam_instance_profile         = var.custom_iam_instance_profile

  vpc_security_group_ids = length(var.sg_ids) < 1 ? aws_security_group.default[*].id : var.sg_ids
  db_subnet_group_name   = var.db_subnet_group_name
  parameter_group_name   = join("", aws_db_instance.this[*].parameter_group_name)
  option_group_name      = join("", aws_db_instance.this[*].option_group_name)
  network_type           = var.network_type

  availability_zone   = var.availability_zone
  multi_az            = var.multi_az
  iops                = var.iops
  storage_throughput  = var.storage_throughput
  publicly_accessible = var.publicly_accessible
  ca_cert_identifier  = var.ca_cert_identifier

  allow_major_version_upgrade = var.allow_major_version_upgrade
  auto_minor_version_upgrade  = var.auto_minor_version_upgrade
  apply_immediately           = var.apply_immediately
  maintenance_window          = var.maintenance_window

  dynamic "blue_green_update" {
    for_each = length(var.blue_green_update) > 0 ? [var.blue_green_update] : []

    content {
      enabled = try(blue_green_update.value.enabled, null)
    }
  }

  snapshot_identifier       = var.snapshot_identifier
  copy_tags_to_snapshot     = var.copy_tags_to_snapshot
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = module.labels.id

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.performance_insights_kms_key_id : null

  replicate_source_db     = join("", aws_db_instance.this[*].identifier)
  replica_mode            = var.replica_mode
  backup_retention_period = length(var.blue_green_update) > 0 ? coalesce(var.backup_retention_period, 1) : var.backup_retention_period
  backup_window           = var.backup_window
  max_allocated_storage   = var.max_allocated_storage
  monitoring_interval     = var.monitoring_interval
  monitoring_role_arn     = join("", aws_iam_role.enhanced_monitoring[*].arn)

  character_set_name              = var.character_set_name
  timezone                        = var.timezone
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  deletion_protection      = var.deletion_protection
  delete_automated_backups = var.delete_automated_backups

  dynamic "restore_to_point_in_time" {
    for_each = var.restore_to_point_in_time != null ? [var.restore_to_point_in_time] : []

    content {
      restore_time                             = lookup(restore_to_point_in_time.value, "restore_time", null)
      source_db_instance_automated_backups_arn = lookup(restore_to_point_in_time.value, "source_db_instance_automated_backups_arn", null)
      source_db_instance_identifier            = lookup(restore_to_point_in_time.value, "source_db_instance_identifier", null)
      source_dbi_resource_id                   = lookup(restore_to_point_in_time.value, "source_dbi_resource_id", null)
      use_latest_restorable_time               = lookup(restore_to_point_in_time.value, "use_latest_restorable_time", null)
    }
  }

  dynamic "s3_import" {
    for_each = var.s3_import != null ? [var.s3_import] : []

    content {
      source_engine         = "mysql"
      source_engine_version = s3_import.value.source_engine_version
      bucket_name           = s3_import.value.bucket_name
      bucket_prefix         = lookup(s3_import.value, "bucket_prefix", null)
      ingestion_role        = s3_import.value.ingestion_role
    }
  }

  tags = merge(
    module.labels.tags,
    var.db_instance_read_tags
  )

  depends_on = [aws_cloudwatch_log_group.this]

  timeouts {
    create = lookup(var.timeouts, "create", null)
    delete = lookup(var.timeouts, "delete", null)
    update = lookup(var.timeouts, "update", null)
  }
}

resource "aws_ssm_parameter" "secret-endpoint" {
  count = var.enabled && var.ssm_parameter_endpoint_enabled ? 1 : 0

  name        = format("/%s/%s/endpoint", var.environment, var.name)
  description = var.ssm_parameter_description
  type        = var.ssm_parameter_type
  value       = join("", aws_db_instance.this[*].endpoint)
  key_id      = var.kms_key_id == "" ? join("", aws_kms_key.default[*].arn) : var.kms_key_id
}
