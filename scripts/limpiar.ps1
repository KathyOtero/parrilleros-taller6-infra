param(
    [ValidateSet('Preparar', 'AplicarPreparacion', 'PlanDestruccion', 'Destruir', 'Verificar')]
    [string]$Paso = 'Preparar'
)

$ErrorActionPreference = 'Stop'
$repoDir = Split-Path -Parent $PSScriptRoot
$infraDir = Join-Path $repoDir 'terraform'
$localDir = Join-Path $repoDir 'work/limpieza'
$evidenceDir = Join-Path $repoDir 'evidence'
$overridePath = Join-Path $infraDir 'limpieza_override.tf'
$prepPlan = Join-Path $localDir 'preparacion.tfplan'
$destroyPlan = Join-Path $localDir 'destruccion.tfplan'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Run-Terraform {
    param([string[]]$Arguments, [string]$LogFile)
    if ($LogFile) {
        & terraform "-chdir=$infraDir" @Arguments 2>&1 | Tee-Object -FilePath $LogFile | Out-Host
    } else {
        & terraform "-chdir=$infraDir" @Arguments | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw 'Terraform fallo. Conserva el estado y envia el error; no reinicies desde cero.' }
}

function Get-StateDocument {
    $stateText = & terraform "-chdir=$infraDir" show -json
    if ($LASTEXITCODE -ne 0) { throw 'No fue posible leer el estado.' }
    return (($stateText -join "`n") | ConvertFrom-Json)
}

function Get-PlanDocument {
    param([string]$Path)
    $planText = & terraform "-chdir=$infraDir" show -json $Path
    if ($LASTEXITCODE -ne 0) { throw 'No fue posible leer el plan.' }
    return (($planText -join "`n") | ConvertFrom-Json)
}

if (!(Test-Path -LiteralPath (Join-Path $infraDir 'compute.tf'))) {
    throw 'Coloca este script en scripts/limpiar.ps1 dentro del repositorio.'
}
$env:AWS_PROFILE = 'parrilleros'
$env:AWS_REGION = 'us-east-1'
$identityText = & aws sts get-caller-identity --profile parrilleros --region us-east-1 --output json --no-cli-pager
if ($LASTEXITCODE -ne 0) { throw 'Sesion AWS no disponible. Inicia sesion con aws login --profile parrilleros.' }
$identity = ($identityText -join "`n") | ConvertFrom-Json
if ($identity.Account -ne '793835018787' -or $identity.Arn -notmatch ':user/parrilleros-deploy$') {
    throw 'Cuenta o usuario inesperados. Este script solo admite la cuenta del laboratorio y parrilleros-deploy.'
}
New-Item -ItemType Directory -Force -Path $localDir, $evidenceDir | Out-Null

if ($Paso -eq 'Preparar') {
    if (Test-Path -LiteralPath $overridePath) {
        throw 'Ya existe limpieza_override.tf. No se sobrescribio. Si es de esta limpieza, continua con el paso correspondiente.'
    }
    $state = Get-StateDocument
    $resources = @($state.values.root_module.resources | Where-Object { $_.mode -eq 'managed' })
    if (!$resources.Count) { throw 'No hay recursos administrados en el estado. No se considera prueba de destruccion.' }
    foreach ($resource in $resources) {
        if ($resource.values.region -and $resource.values.region -ne 'us-east-1') {
            throw ('Recurso fuera de la region prevista: ' + $resource.address)
        }
        if ($resource.values.tags_all.Team -ne 'LOS PARRILLEROS' -and $resource.type -in @('aws_vpc','aws_s3_bucket','aws_dynamodb_table','aws_ecs_cluster','aws_ecr_repository','aws_kms_key')) {
            throw ('Recurso sin tag esperado: ' + $resource.address)
        }
    }
    $expectedBuckets = @('empleados-cloudtrail-793835018787','empleados-access-logs-793835018787')
    foreach ($bucket in @($resources | Where-Object type -eq 'aws_s3_bucket')) {
        if ($bucket.values.bucket -notin $expectedBuckets) { throw 'Bucket ajeno al alcance de la limpieza.' }
    }
    $task = $resources | Where-Object address -eq 'aws_ecs_task_definition.api'
    $containers = @($task.values.container_definitions | ConvertFrom-Json)
    $image = [string]$containers[0].image
    if (!$image.StartsWith('793835018787.dkr.ecr.us-east-1.amazonaws.com/parrilleros-dev-api:')) {
        throw 'Imagen inesperada. No se prepararon cambios.'
    }
    $tag = $image.Substring($image.LastIndexOf(':') + 1)
    $sg = $resources | Where-Object address -eq 'aws_security_group.api'
    $cidr = [string]$sg.values.ingress[0].cidr_blocks[0]
    $env:TF_VAR_deploy_api = 'false'
    $env:TF_VAR_image_tag = $tag
    $env:TF_VAR_allowed_client_cidr = $cidr
    $values = @{deploy_api=$false;image_tag=$tag;allowed_client_cidr=$cidr}
    [System.IO.File]::WriteAllText((Join-Path $localDir 'valores.json'), ($values | ConvertTo-Json), $utf8)
    # Inventario sin valores secretos; conservar fuera de Git.
    $inventory = @($resources | ForEach-Object {
        [ordered]@{address=$_.address;type=$_.type;id=$_.values.id;arn=$_.values.arn}
    })
    [System.IO.File]::WriteAllText((Join-Path $localDir 'inventario.json'), ($inventory | ConvertTo-Json -Depth 5), $utf8)
    $override = @'
# SOLO PARA LIMPIEZA LOCAL. No subir a Git. Retirar despues de destruccion verificada.
resource "aws_s3_bucket" "cloudtrail_logs" {
  force_destroy = true
  lifecycle {
    prevent_destroy = false
  }
}
resource "aws_s3_bucket" "access_logs" {
  force_destroy = true
  lifecycle {
    prevent_destroy = false
  }
}
resource "aws_ecr_repository" "api" {
  force_delete = true
}
resource "aws_cloudtrail" "empleados" {
  enable_logging = false
}
resource "aws_s3_bucket_logging" "cloudtrail_logs" {
  count = 0
}
'@
    [System.IO.File]::WriteAllText($overridePath, $override, $utf8)
    Run-Terraform -Arguments @('plan', '-input=false', '-no-color', "-out=$prepPlan") -LogFile (Join-Path $localDir 'plan-preparacion.txt')
    $plan = Get-PlanDocument -Path $prepPlan
    $destructive = @($plan.resource_changes | Where-Object { $_.change.actions -contains 'delete' })
    foreach ($change in $destructive) {
        if ($change.address -notmatch '^aws_ecs_service\.api\[0\]$|^aws_ecs_task_definition\.api$|^aws_s3_bucket_logging\.cloudtrail_logs(\[0\])?$') {
            throw ('El plan de preparacion elimina un recurso inesperado: ' + $change.address + '. No lo apliques.')
        }
    }
    Write-Host 'PLAN GENERADO. Aun no se modifico AWS. Revisa el resumen antes de AplicarPreparacion.'
    exit 0
}

$valuesPath = Join-Path $localDir 'valores.json'
if (!(Test-Path -LiteralPath $valuesPath)) { throw 'Falta la preparacion local. Ejecuta primero -Paso Preparar.' }
$values = Get-Content -LiteralPath $valuesPath -Raw | ConvertFrom-Json
$env:TF_VAR_deploy_api = 'false'
$env:TF_VAR_image_tag = $values.image_tag
$env:TF_VAR_allowed_client_cidr = $values.allowed_client_cidr

switch ($Paso) {
    'AplicarPreparacion' {
        if (!(Test-Path -LiteralPath $prepPlan)) { throw 'Falta el plan de preparacion.' }
        Run-Terraform -Arguments @('apply', '-no-color', $prepPlan) -LogFile (Join-Path $evidenceDir 'limpieza-preparacion.txt')
        Write-Host 'Preparacion aplicada. API detenida y permisos de limpieza registrados en el estado. Siguiente: PlanDestruccion.'
    }
    'PlanDestruccion' {
        $state = Get-StateDocument
        foreach ($address in @('aws_s3_bucket.cloudtrail_logs','aws_s3_bucket.access_logs')) {
            $bucket = $state.values.root_module.resources | Where-Object address -eq $address
            if (!$bucket -or !$bucket.values.force_destroy) { throw 'Primero aplica la preparacion para registrar force_destroy en el estado.' }
        }
        Run-Terraform -Arguments @('plan', '-destroy', '-input=false', '-no-color', "-out=$destroyPlan") -LogFile (Join-Path $localDir 'plan-destruccion.txt')
        $plan = Get-PlanDocument -Path $destroyPlan
        foreach ($change in @($plan.resource_changes | Where-Object { $_.mode -eq 'managed' })) {
            if ($change.change.actions -contains 'create' -or $change.change.actions -contains 'update') {
                throw 'El plan no es una destruccion pura. No aplicar.'
            }
        }
        Write-Host 'PLAN DE DESTRUCCION GENERADO. Revisar antes de Destruir. Incluye tablas, versiones de objetos y todas las imagenes del repositorio.'
    }
    'Destruir' {
        if (!(Test-Path -LiteralPath $destroyPlan)) { throw 'Falta PlanDestruccion.' }
        Run-Terraform -Arguments @('apply', '-no-color', $destroyPlan) -LogFile (Join-Path $evidenceDir 'terraform-destroy.txt')
        Write-Host 'Plan de destruccion aplicado. Ejecuta Verificar y conserva evidencia.'
    }
    'Verificar' {
        $state = Get-StateDocument
        $managed = @($state.values.root_module.resources | Where-Object { $_.mode -eq 'managed' })
        if ($managed.Count -gt 0) { throw ('Aun hay ' + $managed.Count + ' recursos en el estado. No se certifica limpieza.') }
        # Windows PowerShell 5.1 puede conservar el array JSON como un solo
        # elemento si se envuelve esta tuberia en @(...).
        $inventory = Get-Content -LiteralPath (Join-Path $localDir 'inventario.json') -Raw | ConvertFrom-Json
        $checks = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $inventory) {
            $response = $null
            $expected = $null
            # Los NotFound son resultados esperados, no fallos PowerShell del script.
            $ErrorActionPreference = 'Continue'
            switch ($entry.type) {
                'aws_dynamodb_table' {
                    $response = & aws dynamodb describe-table --table-name $entry.id --region us-east-1 --profile parrilleros --no-cli-pager 2>&1
                    $expected = 'ResourceNotFoundException'
                }
                'aws_ecr_repository' {
                    $response = & aws ecr describe-repositories --repository-names $entry.id --region us-east-1 --profile parrilleros --no-cli-pager 2>&1
                    $expected = 'RepositoryNotFoundException'
                }
                'aws_s3_bucket' {
                    $response = & aws s3api head-bucket --bucket $entry.id --profile parrilleros --no-cli-pager 2>&1
                    $expected = '\(404\)|Not Found|NoSuchBucket'
                }
                'aws_vpc' {
                    $response = & aws ec2 describe-vpcs --vpc-ids $entry.id --region us-east-1 --profile parrilleros --no-cli-pager 2>&1
                    $expected = 'InvalidVpcID.NotFound'
                }
                'aws_kms_key' {
                    $response = & aws kms describe-key --key-id $entry.id --region us-east-1 --profile parrilleros --output json --no-cli-pager 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ('No se pudo consultar KMS: ' + ($response -join "`n")) }
                    $key = ($response -join "`n") | ConvertFrom-Json
                    if ($key.KeyMetadata.KeyState -ne 'PendingDeletion') { throw 'Clave KMS no programada para eliminacion.' }
                    $checks.Add($entry.address + ': KMS PendingDeletion; eliminacion diferida, no inmediata.')
                }
            }
            $ErrorActionPreference = 'Stop'
            if ($expected) {
                if ($LASTEXITCODE -eq 0 -or ($response -join "`n") -notmatch $expected) {
                    throw ('No se confirmo ausencia de ' + $entry.address + ': ' + ($response -join "`n"))
                }
                $checks.Add($entry.address + ': ausencia confirmada por AWS.')
            }
        }
        $report = @(
            'Fecha UTC: ' + [DateTime]::UtcNow.ToString('o'),
            'Cuenta: 793835018787. Region: us-east-1.',
            'Recursos administrados restantes en el estado: 0.',
            'Se aplico un plan terraform plan -destroy mediante terraform apply (equivalente revisable de terraform destroy).'
        ) + $checks.ToArray() + @(
            'KMS se elimina tras la espera configurada de 30 dias.',
            'No se eliminaron el usuario de despliegue, sus politicas ni roles vinculados al servicio creados por AWS fuera del estado.',
            'No se afirma coste cero inmediato: facturacion y registros pueden reflejarse con retraso.'
        )
        [System.IO.File]::WriteAllLines((Join-Path $evidenceDir 'verificacion-limpieza.txt'), [string[]]$report, $utf8)
        Write-Host ($report -join "`n")
        Write-Host 'Conserva el estado local y los planes fuera de Git. El override local puede retirarse ahora antes de futuros despliegues.'
    }
}
