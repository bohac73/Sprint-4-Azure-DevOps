# ============================================================================
# Script: setup-azure-resources.ps1
# Descrição: Script para criar e configurar recursos do Azure antes do build
# Autor: TechLab DevOps
# ============================================================================
# Este script é executado no pipeline Azure DevOps antes do build
# Responsabilidades:
# - Criar Resource Group (se não existir)
# - Criar Azure Database for PostgreSQL (se não existir)
# - Criar Storage Account (se necessário)
# - Criar Container Registry (se necessário)
# - Configurar firewall rules
# - Validar recursos criados
# ============================================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = $env:AZURE_RESOURCE_GROUP_NAME,
    
    [Parameter(Mandatory = $false)]
    [string]$Location = $env:AZURE_LOCATION,
    
    [Parameter(Mandatory = $false)]
    [string]$PostgreSqlServerName = $env:AZURE_POSTGRESQL_SERVER_NAME,
    
    [Parameter(Mandatory = $false)]
    [string]$PostgreSqlAdminUser = $env:AZURE_POSTGRESQL_ADMIN_USER,
    
    [Parameter(Mandatory = $false)]
    [string]$PostgreSqlAdminPassword = $env:AZURE_POSTGRESQL_ADMIN_PASSWORD,
    
    [Parameter(Mandatory = $false)]
    [string]$PostgreSqlDatabaseName = $env:AZURE_POSTGRESQL_DATABASE_NAME,
    
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName = $env:AZURE_STORAGE_ACCOUNT_NAME,
    
    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistryName = $env:AZURE_CONTAINER_REGISTRY_NAME,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipDatabaseCreation = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipStorageCreation = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipContainerRegistryCreation = $false
)

# ============================================================================
# Configuração de Error Handling
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================================
# Funções Auxiliares
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        default { "White" }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    Write-Host "[$timestamp] [$Level] $Message" | Out-File -FilePath "azure-setup.log" -Append -Encoding UTF8
}

function Test-AzureConnection {
    Write-Log "Verificando conexão com Azure..." "Info"
    
    try {
        # Verifica se o módulo Az está instalado
        $azModule = Get-Module -ListAvailable -Name Az.Accounts
        if ($null -eq $azModule) {
            Write-Log "Módulo Az.Accounts não encontrado. Tentando importar..." "Warning"
            Import-Module Az.Accounts -ErrorAction Stop
            Write-Log "Módulo Az.Accounts importado com sucesso" "Success"
        }
        
        # Tenta obter o contexto atual do Azure
        $context = Get-AzContext -ErrorAction SilentlyContinue
        
        if ($null -eq $context) {
            Write-Log "Não há contexto do Azure. Tentando fazer login..." "Warning"
            
            # Detecta se está rodando no Azure DevOps
            $isAzureDevOps = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI -ne $null
            
            if ($isAzureDevOps) {
                Write-Log "Detectado ambiente Azure DevOps" "Info"
                
                # Primeiro, tenta verificar se o Azure CLI já está autenticado (comum quando usa task Azure CLI)
                $azCliAvailable = Get-Command az -ErrorAction SilentlyContinue
                if ($null -ne $azCliAvailable) {
                    Write-Log "Verificando se Azure CLI está autenticado..." "Info"
                    $azAccountOutput = az account show 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Azure CLI está autenticado. Tentando importar contexto para PowerShell..." "Info"
                        try {
                            # Tenta importar o contexto do Azure CLI
                            $azureProfilePath = Join-Path $env:USERPROFILE ".azure\azureProfile.json"
                            if (Test-Path $azureProfilePath) {
                                $context = Import-AzContext -Path $azureProfilePath -ErrorAction SilentlyContinue
                                if ($null -ne $context) {
                                    Write-Log "Contexto do Azure CLI importado com sucesso para PowerShell" "Success"
                                }
                            }
                            
                            # Se não conseguiu importar, tenta usar o método alternativo
                            if ($null -eq $context) {
                                # Obtém informações da conta do Azure CLI
                                $azAccountJson = az account show | ConvertFrom-Json
                                if ($azAccountJson) {
                                    Write-Log "Obtendo credenciais do Azure CLI para autenticar PowerShell..." "Info"
                                    # Tenta autenticar usando as mesmas credenciais
                                    # No Azure DevOps, o Azure CLI já está autenticado via Service Connection
                                    # Precisamos obter as credenciais das variáveis de ambiente
                                }
                            }
                        }
                        catch {
                            Write-Log "Não foi possível importar contexto do Azure CLI: $($_.Exception.Message)" "Warning"
                        }
                    }
                }
                
                # Se ainda não tem contexto, tenta autenticar usando Service Principal
                if ($null -eq $context) {
                    Write-Log "Tentando autenticar usando Service Principal do Azure DevOps..." "Info"
                    
                    # No Azure DevOps, quando usando task "Azure PowerShell", a autenticação já deve estar feita
                    # Mas se não estiver, tenta usar as variáveis de ambiente da Service Connection
                    # Variáveis podem ter diferentes nomes dependendo da versão da task
                    # Tenta obter das variáveis de ambiente (múltiplos formatos possíveis)
                    $servicePrincipalId = if (-not [string]::IsNullOrWhiteSpace($env:servicePrincipalId)) { 
                        $env:servicePrincipalId 
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:SERVICE_PRINCIPAL_ID)) { 
                        $env:SERVICE_PRINCIPAL_ID 
                    } else { 
                        $env:AZURE_CLIENT_ID 
                    }
                    
                    $servicePrincipalKey = if (-not [string]::IsNullOrWhiteSpace($env:servicePrincipalKey)) { 
                        $env:servicePrincipalKey 
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:SERVICE_PRINCIPAL_KEY)) { 
                        $env:SERVICE_PRINCIPAL_KEY 
                    } else { 
                        $env:AZURE_CLIENT_SECRET 
                    }
                    
                    $tenantId = if (-not [string]::IsNullOrWhiteSpace($env:tenantId)) { 
                        $env:tenantId 
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:TENANT_ID)) { 
                        $env:TENANT_ID 
                    } else { 
                        $env:AZURE_TENANT_ID 
                    }
                    
                    $subscriptionId = if (-not [string]::IsNullOrWhiteSpace($env:subscriptionId)) { 
                        $env:subscriptionId 
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:SUBSCRIPTION_ID)) { 
                        $env:SUBSCRIPTION_ID 
                    } else { 
                        $env:AZURE_SUBSCRIPTION_ID 
                    }
                    
                    # Se encontrou as credenciais, tenta autenticar
                    if (-not [string]::IsNullOrWhiteSpace($servicePrincipalId) -and 
                        -not [string]::IsNullOrWhiteSpace($servicePrincipalKey) -and 
                        -not [string]::IsNullOrWhiteSpace($tenantId) -and 
                        -not [string]::IsNullOrWhiteSpace($subscriptionId)) {
                        
                        Write-Log "Autenticando usando Service Principal..." "Info"
                        
                        try {
                            $securePassword = ConvertTo-SecureString $servicePrincipalKey -AsPlainText -Force
                            $psCredential = New-Object System.Management.Automation.PSCredential($servicePrincipalId, $securePassword)
                            
                            Connect-AzAccount `
                                -ServicePrincipal `
                                -Credential $psCredential `
                                -TenantId $tenantId `
                                -SubscriptionId $subscriptionId `
                                -Environment "AzureCloud" `
                                -ErrorAction Stop | Out-Null
                            
                            Write-Log "Autenticação via Service Principal concluída" "Success"
                            
                            # Obtém o contexto novamente após autenticação
                            $context = Get-AzContext -ErrorAction SilentlyContinue
                        }
                        catch {
                            Write-Log "Erro ao autenticar com Service Principal: $($_.Exception.Message)" "Error"
                            throw "Falha na autenticação com Service Principal. Verifique as credenciais da Service Connection."
                        }
                    }
                    else {
                        Write-Log "Credenciais de Service Principal não encontradas nas variáveis de ambiente" "Warning"
                        Write-Log "Certifique-se de que está usando uma task 'Azure PowerShell' ou 'Azure CLI' com Service Connection configurada" "Warning"
                        throw "Não foi possível encontrar credenciais para autenticação no Azure DevOps."
                    }
                }
            }
            else {
                # Ambiente local ou outro contexto
                Write-Log "Ambiente local detectado. Tentando autenticar via Azure CLI..." "Info"
                
                # Verifica se Azure CLI está disponível
                $azCliAvailable = Get-Command az -ErrorAction SilentlyContinue
                
                if ($null -ne $azCliAvailable) {
                    $azAccount = az account show 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Azure CLI está autenticado" "Info"
                        # Tenta importar o contexto do Azure CLI
                        try {
                            $azureProfilePath = Join-Path $env:USERPROFILE ".azure\azureProfile.json"
                            if (Test-Path $azureProfilePath) {
                                $context = Import-AzContext -Path $azureProfilePath -ErrorAction SilentlyContinue
                                if ($null -ne $context) {
                                    Write-Log "Contexto do Azure CLI importado com sucesso" "Success"
                                }
                            }
                        }
                        catch {
                            Write-Log "Não foi possível importar contexto do Azure CLI: $($_.Exception.Message)" "Warning"
                        }
                    }
                }
                
                if ($null -eq $context) {
                    throw "Não foi possível autenticar. Execute 'az login' ou 'Connect-AzAccount' antes de executar o script."
                }
            }
        }
        
        if ($null -eq $context) {
            throw "Não foi possível estabelecer conexão com Azure após tentativas de autenticação."
        }
        
        Write-Log "Conectado ao Azure como: $($context.Account.Id)" "Success"
        Write-Log "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" "Info"
        return $true
    }
    catch {
        Write-Log "Erro ao verificar conexão com Azure: $($_.Exception.Message)" "Error"
        Write-Log "Detalhes do erro: $($_.Exception.GetType().FullName)" "Error"
        
        # Log adicional para debug
        if ($env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI) {
            Write-Log "Variáveis de ambiente disponíveis:" "Info"
            Write-Log "  AZURE_CLIENT_ID: $([string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID))" "Info"
            Write-Log "  AZURE_TENANT_ID: $([string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID))" "Info"
            Write-Log "  AZURE_SUBSCRIPTION_ID: $([string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID))" "Info"
        }
        
        return $false
    }
}

function New-ResourceGroupIfNotExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$Location
    )
    
    Write-Log "Verificando Resource Group: $Name" "Info"
    
    try {
        $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
        
        if ($null -eq $rg) {
            Write-Log "Resource Group não encontrado. Criando..." "Info"
            $rg = New-AzResourceGroup -Name $Name -Location $Location -Force
            Write-Log "Resource Group criado com sucesso: $Name" "Success"
        }
        else {
            Write-Log "Resource Group já existe: $Name" "Info"
        }
        
        return $rg
    }
    catch {
        Write-Log "Erro ao criar/verificar Resource Group: $($_.Exception.Message)" "Error"
        throw
    }
}

function New-PostgreSqlServerIfNotExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$Location,
        
        [Parameter(Mandatory = $true)]
        [string]$AdminUser,
        
        [Parameter(Mandatory = $true)]
        [string]$AdminPassword,
        
        [Parameter(Mandatory = $true)]
        [string]$DatabaseName
    )
    
    Write-Log "Verificando PostgreSQL Server: $ServerName" "Info"
    
    try {
        $server = Get-AzPostgreSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction SilentlyContinue
        
        if ($null -eq $server) {
            Write-Log "PostgreSQL Server não encontrado. Criando..." "Info"
            
            # Validação de senha
            if ($AdminPassword.Length -lt 8) {
                throw "A senha do PostgreSQL deve ter pelo menos 8 caracteres"
            }
            
            # Cria o servidor PostgreSQL
            $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
            $server = New-AzPostgreSqlServer `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -Location $Location `
                -SkuName "B_Gen5_1" `
                -SkuTier "Basic" `
                -AdministratorLogin $AdminUser `
                -AdministratorLoginPassword $securePassword `
                -Version "13" `
                -StorageInMB 51200 `
                -BackupRetentionDay 7 `
                -GeoRedundantBackup "Disabled" `
                -SslEnforcement "Enabled"
            
            Write-Log "PostgreSQL Server criado com sucesso: $ServerName" "Success"
            
            # Aguarda o servidor estar pronto
            Write-Log "Aguardando servidor estar pronto..." "Info"
            Start-Sleep -Seconds 30
            
            # Configura firewall para permitir acesso do Azure
            Write-Log "Configurando firewall rules..." "Info"
            New-AzPostgreSqlFirewallRule `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -FirewallRuleName "AllowAzureServices" `
                -StartIpAddress "0.0.0.0" `
                -EndIpAddress "0.0.0.0" `
                -ErrorAction SilentlyContinue | Out-Null
            
            Write-Log "Firewall rule 'AllowAzureServices' configurada" "Success"
        }
        else {
            Write-Log "PostgreSQL Server já existe: $ServerName" "Info"
        }
        
        # Cria o banco de dados se não existir
        Write-Log "Verificando banco de dados: $DatabaseName" "Info"
        $database = Get-AzPostgreSqlDatabase `
            -ResourceGroupName $ResourceGroupName `
            -ServerName $ServerName `
            -DatabaseName $DatabaseName `
            -ErrorAction SilentlyContinue
        
        if ($null -eq $database) {
            Write-Log "Banco de dados não encontrado. Criando..." "Info"
            $database = New-AzPostgreSqlDatabase `
                -ResourceGroupName $ResourceGroupName `
                -ServerName $ServerName `
                -DatabaseName $DatabaseName `
                -Charset "UTF8" `
                -Collation "en_US.utf8"
            
            Write-Log "Banco de dados criado com sucesso: $DatabaseName" "Success"
        }
        else {
            Write-Log "Banco de dados já existe: $DatabaseName" "Info"
        }
        
        return $server
    }
    catch {
        Write-Log "Erro ao criar/verificar PostgreSQL Server: $($_.Exception.Message)" "Error"
        throw
    }
}

function New-StorageAccountIfNotExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$Location
    )
    
    Write-Log "Verificando Storage Account: $StorageAccountName" "Info"
    
    try {
        $storageAccount = Get-AzStorageAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $StorageAccountName `
            -ErrorAction SilentlyContinue
        
        if ($null -eq $storageAccount) {
            Write-Log "Storage Account não encontrado. Criando..." "Info"
            
            # Validação do nome do storage account (deve ser único globalmente)
            $available = Test-AzStorageAccountNameAvailability -Name $StorageAccountName
            if (-not $available.NameAvailable) {
                throw "Nome do Storage Account não está disponível: $StorageAccountName"
            }
            
            $storageAccount = New-AzStorageAccount `
                -ResourceGroupName $ResourceGroupName `
                -Name $StorageAccountName `
                -Location $Location `
                -SkuName "Standard_LRS" `
                -Kind "StorageV2" `
                -AccessTier "Hot"
            
            Write-Log "Storage Account criado com sucesso: $StorageAccountName" "Success"
        }
        else {
            Write-Log "Storage Account já existe: $StorageAccountName" "Info"
        }
        
        return $storageAccount
    }
    catch {
        Write-Log "Erro ao criar/verificar Storage Account: $($_.Exception.Message)" "Error"
        throw
    }
}

function New-ContainerRegistryIfNotExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$Location
    )
    
    Write-Log "Verificando Container Registry: $RegistryName" "Info"
    
    try {
        $registry = Get-AzContainerRegistry `
            -ResourceGroupName $ResourceGroupName `
            -Name $RegistryName `
            -ErrorAction SilentlyContinue
        
        if ($null -eq $registry) {
            Write-Log "Container Registry não encontrado. Criando..." "Info"
            
            $registry = New-AzContainerRegistry `
                -ResourceGroupName $ResourceGroupName `
                -Name $RegistryName `
                -Location $Location `
                -Sku "Basic" `
                -AdminEnabled $true
            
            Write-Log "Container Registry criado com sucesso: $RegistryName" "Success"
        }
        else {
            Write-Log "Container Registry já existe: $RegistryName" "Info"
        }
        
        return $registry
    }
    catch {
        Write-Log "Erro ao criar/verificar Container Registry: $($_.Exception.Message)" "Error"
        throw
    }
}

function Get-ConnectionString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,
        
        [Parameter(Mandatory = $true)]
        [string]$DatabaseName,
        
        [Parameter(Mandatory = $true)]
        [string]$AdminUser,
        
        [Parameter(Mandatory = $true)]
        [string]$AdminPassword
    )
    
    # Obtém o FQDN do servidor
    $server = Get-AzPostgreSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName
    $fqdn = $server.FullyQualifiedDomainName
    
    # Formata a connection string no formato PostgreSQL
    $connectionString = "Host=$fqdn;Port=5432;Database=$DatabaseName;Username=$AdminUser@$ServerName;Password=$AdminPassword;Ssl Mode=Require;"
    
    return $connectionString
}

# ============================================================================
# Script Principal
# ============================================================================

Write-Log "================================================" "Info"
Write-Log "Iniciando setup de recursos do Azure" "Info"
Write-Log "================================================" "Info"

try {
    # Validação de parâmetros obrigatórios
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw "ResourceGroupName é obrigatório. Configure a variável AZURE_RESOURCE_GROUP_NAME ou passe como parâmetro."
    }
    
    if ([string]::IsNullOrWhiteSpace($Location)) {
        $Location = "brazilsouth"
        Write-Log "Location não especificado. Usando padrão: $Location" "Warning"
    }
    
    # Verifica conexão com Azure
    if (-not (Test-AzureConnection)) {
        throw "Não foi possível conectar ao Azure. Verifique se você está autenticado."
    }
    
    # Cria Resource Group
    $resourceGroup = New-ResourceGroupIfNotExists -Name $ResourceGroupName -Location $Location
    
    # Cria PostgreSQL Server e Database
    if (-not $SkipDatabaseCreation) {
        if ([string]::IsNullOrWhiteSpace($PostgreSqlServerName)) {
            Write-Log "PostgreSqlServerName não especificado. Pulando criação do banco de dados." "Warning"
        }
        elseif ([string]::IsNullOrWhiteSpace($PostgreSqlAdminUser) -or [string]::IsNullOrWhiteSpace($PostgreSqlAdminPassword)) {
            Write-Log "Credenciais do PostgreSQL não especificadas. Pulando criação do banco de dados." "Warning"
        }
        else {
            if ([string]::IsNullOrWhiteSpace($PostgreSqlDatabaseName)) {
                $PostgreSqlDatabaseName = "techlab"
                Write-Log "DatabaseName não especificado. Usando padrão: $PostgreSqlDatabaseName" "Info"
            }
            
            $postgreSqlServer = New-PostgreSqlServerIfNotExists `
                -ServerName $PostgreSqlServerName `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -AdminUser $PostgreSqlAdminUser `
                -AdminPassword $PostgreSqlAdminPassword `
                -DatabaseName $PostgreSqlDatabaseName
            
            # Gera connection string
            $connectionString = Get-ConnectionString `
                -ServerName $PostgreSqlServerName `
                -DatabaseName $PostgreSqlDatabaseName `
                -AdminUser $PostgreSqlAdminUser `
                -AdminPassword $PostgreSqlAdminPassword
            
            Write-Log "Connection String gerada (ocultando senha): $($connectionString -replace 'Password=[^;]+', 'Password=***')" "Info"
            
            # Define como variável de ambiente para uso no pipeline
            Write-Host "##vso[task.setvariable variable=AZURE_POSTGRESQL_CONNECTION_STRING]$connectionString"
            Write-Log "Connection String definida como variável de pipeline: AZURE_POSTGRESQL_CONNECTION_STRING" "Success"
        }
    }
    else {
        Write-Log "Criação do banco de dados foi pulada (SkipDatabaseCreation=true)" "Info"
    }
    
    # Cria Storage Account
    if (-not $SkipStorageCreation) {
        if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
            Write-Log "StorageAccountName não especificado. Pulando criação do Storage Account." "Info"
        }
        else {
            $storageAccount = New-StorageAccountIfNotExists `
                -StorageAccountName $StorageAccountName `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location
        }
    }
    else {
        Write-Log "Criação do Storage Account foi pulada (SkipStorageCreation=true)" "Info"
    }
    
    # Cria Container Registry
    if (-not $SkipContainerRegistryCreation) {
        if ([string]::IsNullOrWhiteSpace($ContainerRegistryName)) {
            Write-Log "ContainerRegistryName não especificado. Pulando criação do Container Registry." "Info"
        }
        else {
            $containerRegistry = New-ContainerRegistryIfNotExists `
                -RegistryName $ContainerRegistryName `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location
        }
    }
    else {
        Write-Log "Criação do Container Registry foi pulada (SkipContainerRegistryCreation=true)" "Info"
    }
    
    Write-Log "================================================" "Info"
    Write-Log "Setup de recursos do Azure concluído com sucesso!" "Success"
    Write-Log "================================================" "Info"
    
    exit 0
}
catch {
    Write-Log "================================================" "Error"
    Write-Log "Erro durante o setup de recursos do Azure" "Error"
    Write-Log "Mensagem: $($_.Exception.Message)" "Error"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" "Error"
    Write-Log "================================================" "Error"
    exit 1
}

