<#
.SYNOPSIS
    Script único para instalación, configuración y generación de informes avanzados de vSphere
.DESCRIPTION
    Este script automatiza:
    - Instalación limpia de VMware PowerCLI
    - Configuración del entorno
    - Conexión a vCenter/ESXi
    - Generación de informes: CPU Ready, RAM, Red e IOPS
.NOTES
    Versión: 1.0
    Fecha: 2025-06-20
    Autor: [Tu Nombre]
#>

# 1. CONFIGURACIÓN INICIAL
Write-Host "`n🚀 INICIANDO INSTALACIÓN Y CONFIGURACIÓN DE POWERCLI" -ForegroundColor Cyan
Write-Host "=================================================`n"

# 1.1. Verificar ejecución como administrador
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "⚠️ ADVERTENCIA: Algunas funciones pueden requerir privilegios de administrador" -ForegroundColor Yellow
}

# 1.2. Configurar política de ejecución
try {
    $executionPolicy = Get-ExecutionPolicy
    if ($executionPolicy -ne 'RemoteSigned' -and $executionPolicy -ne 'Unrestricted') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Host "✔️ Política de ejecución configurada a RemoteSigned" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Error configurando política de ejecución: $_" -ForegroundColor Red
}

# 2. LIMPIEZA DE INSTALACIONES PREVIAS
Write-Host "`n🧹 LIMPIANDO INSTALACIONES PREVIAS" -ForegroundColor Cyan
Write-Host "=================================`n"

try {
    # 2.1. Cerrar sesiones existentes
    Get-PSSession | Where-Object { $_.ConfigurationName -eq "VMware.VimAutomation.Core" } | Remove-PSSession -ErrorAction SilentlyContinue
    
    # 2.2. Desinstalar módulos existentes
    $vmwareModules = Get-Module -Name VMware* -ListAvailable | Select-Object -ExpandProperty Name -Unique
    if ($vmwareModules) {
        Write-Host "🔍 Módulos VMware encontrados:" -ForegroundColor Yellow
        $vmwareModules | ForEach-Object { Write-Host "- $_" }
        
        Write-Host "`n🗑️ Desinstalando módulos..." -ForegroundColor Yellow
        $vmwareModules | ForEach-Object {
            try {
                Uninstall-Module -Name $_ -AllVersions -Force -ErrorAction Stop
                Write-Host "✔️ ${_} removido" -ForegroundColor Green
            } catch {
                Write-Host "⚠️ No se pudo remover ${_}: ${_}" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "✔️ No se encontraron módulos VMware instalados" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Error durante la limpieza: $_" -ForegroundColor Red
}

# 3. INSTALACIÓN PRINCIPAL
Write-Host "`n📦 INSTALANDO VMWARE POWERCLI" -ForegroundColor Cyan
Write-Host "===========================`n"

# 3.1. Configurar repositorio
try {
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    }
    Write-Host "✔️ Repositorio PSGallery configurado" -ForegroundColor Green
} catch {
    Write-Host "❌ Error configurando PSGallery: $_" -ForegroundColor Red
}

# 3.2. Instalar versión específica de PowerCLI
$powerCLIVersion = "13.4.0.24798382"
Write-Host "🔍 Instalando VMware.PowerCLI versión $powerCLIVersion" -ForegroundColor Yellow

try {
    Install-Module -Name VMware.PowerCLI -RequiredVersion $powerCLIVersion -Force -AllowClobber -Scope AllUsers -SkipPublisherCheck -ErrorAction Stop
    Import-Module VMware.PowerCLI -RequiredVersion $powerCLIVersion -ErrorAction Stop
    Write-Host "✔️ VMware.PowerCLI instalado y cargado correctamente" -ForegroundColor Green
    
    Write-Host "`n📊 Módulos instalados:" -ForegroundColor Yellow
    Get-Module VMware* -ListAvailable | Select-Object Name, Version | Sort-Object Name | Format-Table -AutoSize
} catch {
    Write-Host "❌ Error crítico durante la instalación: $_" -ForegroundColor Red
    exit 1
}

# 4. CONFIGURACIÓN POST-INSTALACIÓN
Write-Host "`n⚙️ CONFIGURANDO POWERCLI" -ForegroundColor Cyan
Write-Host "=======================`n"

try {
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -DisplayDeprecationWarnings $false -Confirm:$false | Out-Null
    
    Write-Host "✔️ Configuración de PowerCLI completada" -ForegroundColor Green
} catch {
    Write-Host "⚠️ Advertencia en configuración: $_" -ForegroundColor Yellow
}

# 5. CONEXIÓN A VCENTER/ESXi (OPCIONAL)
Write-Host "`n🔌 CONEXIÓN A VCENTER/ESXi" -ForegroundColor Cyan
Write-Host "=========================`n"

$connectToVCenter = Read-Host "¿Deseas conectar a vCenter ahora? (S/N)"
if ($connectToVCenter -eq "S" -or $connectToVCenter -eq "s") {
    try {
        $vCenterServer = Read-Host "Introduce la IP/hostname del vCenter"
        $credential = Get-Credential -Message "Credenciales para $vCenterServer"
        
        Write-Host "`n🔗 Conectando a $vCenterServer..." -ForegroundColor Yellow
        $connection = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop
        
        Write-Host "✔️ Conexión establecida correctamente" -ForegroundColor Green
        Write-Host "   - Servidor: $($connection.Name)"
        Write-Host "   - Usuario: $($connection.User)"
        Write-Host "   - Versión: $($connection.Version)"
        
        # Definir fechas (último mes)
        $endDate = Get-Date
        $startDate = $endDate.AddMonths(-1)

        # Crear carpeta de salida para informes
        $reportFolder = "C:\Temp\VMware_Reports"
        New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null

        # 6. CPU READY
        Write-Host "`n📊 ANALIZANDO CPU READY..." -ForegroundColor Yellow
        $vmStats = @()
        foreach ($vmHost in (Get-VMHost)) {
            foreach ($vm in (Get-VM -Location $vmHost | Where-Object { $_.PowerState -eq "PoweredOn" })) {
                try {
                    $cpuReady = Get-Stat -Entity $vm -Stat cpu.ready.summation -Start $startDate -Finish $endDate -IntervalMins 30 -ErrorAction Stop
                    if ($cpuReady) {
                        $avg = ($cpuReady | Measure-Object Value -Average).Average / $vm.NumCpu
                        $vmStats += [PSCustomObject]@{
                            VMName      = $vm.Name
                            HostName    = $vmHost.Name
                            NumCPUs     = $vm.NumCpu
                            AvgCpuReady = [math]::Round($avg, 2)
                        }
                    }
                } catch {
                    Write-Host "⚠️ Error al recolectar CPU Ready para $($vm.Name): $_" -ForegroundColor Yellow
                }
            }
        }
        $vmStats = $vmStats | Sort-Object AvgCpuReady -Descending | Select-Object -First 20

        # Generar informe HTML - CPU Ready
        $htmlContent = @"
<!DOCTYPE html>
<html lang='es'>
<head>
    <meta charset='UTF-8'>
    <title>Reporte de CPU Ready</title>
    <script src='https://cdn.jsdelivr.net/npm/chart.js'></script> 
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            margin: 0;
            padding: 20px;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
        }
        .container {
            width: 100%;
            max-width: 1000px;
            background-color: #fff;
            box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
            padding: 20px;
            border-radius: 8px;
        }
        canvas {
            height: 400px;
            margin-top: 20px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            padding: 10px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #007BFF;
            color: white;
        }
    </style>
</head>
<body>
<div class='container'>
    <h2>Top 20 Máquinas Virtuales por CPU Ready</h2>
    <canvas id='cpuReadyChart'></canvas>
    <table>
        <thead>
            <tr>
                <th>Nombre VM</th>
                <th>HostName</th>
                <th>vCPUs</th>
                <th>Avg CPU Ready (ms)</th>
            </tr>
        </thead>
        <tbody>
"@

foreach ($stat in $vmStats) {
    $htmlContent += "<tr><td>$($stat.VMName)</td><td>$($stat.HostName)</td><td>$($stat.NumCPUs)</td><td>$($stat.AvgCpuReady)</td></tr>`n"
}

$htmlContent += @"

        </tbody>
    </table>
</div>

<script>
const ctx = document.getElementById('cpuReadyChart').getContext('2d');
new Chart(ctx, {
    type: 'bar',
    data: {
        labels: ["@
+ ($vmStats.VMName | ForEach-Object {"`"$_`""}) -join "," + @"
],
        datasets: [{
            label: 'CPU Ready (ms)',
            data: ["@
+ ($vmStats.AvgCpuReady -join "," + @"
],
            backgroundColor: 'rgba(54, 162, 235, 0.6)'
        }]
    },
    options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
            y: {
                beginAtZero: true,
                ticks: {
                    callback: value => value + ' ms'
                }
            }
        }
    }
});
</script>

</body>
</html>
"@

        # Guardar archivo HTML
        $htmlContent | Out-File -FilePath "$reportFolder\cpu_ready_report.html" -Encoding UTF8
        Write-Host "✔️ Informe de CPU Ready generado." -ForegroundColor Green

        # 7. RAM ASIGNADA VS CONSUMIDA
        Write-Host "`n📊 ANALIZANDO RAM..." -ForegroundColor Yellow
        $fileRAM = "$reportFolder\Combined-RAM.csv"
        New-Item -Path $fileRAM -ItemType File -Force | Out-Null
        Add-Content -Path $fileRAM -Value "VM,AssignedRAMGB,AvgConsumedRAMGB"

        $ramData = @()
        $vms = Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"}
        foreach ($vm in $vms) {
            $assignedRAMGB = [math]::round($vm.MemoryMB / 1024, 2)
            $memStats = Get-Stat -Entity $vm -Stat mem.usage.average -Start $startDate -Finish $endDate
            if ($memStats) {
                $avgRAMPercent = ($memStats | Measure-Object Value -Average).Average
                $avgConsumedRAMGB = [math]::round(($avgRAMPercent * $vm.MemoryGB) / 100, 2)
                Add-Content -Path $fileRAM -Value "$($vm.Name),$assignedRAMGB,$avgConsumedRAMGB"
                $ramData += [PSCustomObject]@{
                    VM = $vm.Name
                    AssignedRAMGB = $assignedRAMGB
                    AvgConsumedRAMGB = $avgConsumedRAMGB
                }
            }
        }

        # Generar informe HTML - RAM
        $htmlRAM = @"
<!DOCTYPE html>
<html lang='es'>
<head>
    <meta charset='UTF-8'>
    <title>Reporte de RAM</title>
    <script src='https://cdn.jsdelivr.net/npm/chart.js'></script> 
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            text-align: center;
            padding: 20px;
        }
        .container {
            max-width: 900px;
            margin: auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.1);
        }
        canvas {
            height: 400px;
            margin-top: 20px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #007BFF;
            color: white;
        }
    </style>
</head>
<body>
<div class='container'>
    <h2>RAM Asignada vs Promedio Consumido</h2>
    <canvas id='ramChart'></canvas>
    <table>
        <thead><tr><th>VM</th><th>RAM Asignada (GB)</th><th>Promedio Consumido (GB)</th></tr></thead>
        <tbody>
"@

        foreach ($row in $ramData) {
            $htmlRAM += "<tr><td>$($row.VM)</td><td>$($row.AssignedRAMGB)</td><td>$($row.AvgConsumedRAMGB)</td></tr>`n"
        }

        $topRAM = $ramData | Sort-Object AssignedRAMGB -Descending | Select-Object -First 10

        $htmlRAM += @"

        </tbody>
    </table>
</div>

<script>
const ramCtx = document.getElementById('ramChart').getContext('2d');
new Chart(ramCtx, {
    type: 'bar',
    data: {
        labels: [`"@ + ($topRAM.VM -join '","') + @""],
        datasets: [
            {
                label: 'RAM Asignada (GB)',
                data: [`"@ + ($topRAM.AssignedRAMGB -join ',') + @"],
                backgroundColor: 'rgba(54, 162, 235, 0.7)'
            },
            {
                label: 'Promedio RAM Consumida (GB)',
                data: [`"@ + ($topRAM.AvgConsumedRAMGB -join ',') + @"],
                backgroundColor: 'rgba(255, 99, 132, 0.7)'
            }
        ]
    },
    options: {
        responsive: true,
        scales: {
            y: {
                beginAtZero: true,
                ticks: { callback: value => value + ' GB' }
            }
        }
    }
});
</script>

</body>
</html>
"@

        $htmlRAM | Out-File "$reportFolder\ram_usage_report.html" -Encoding UTF8
        Write-Host "✔️ Informe de RAM generado." -ForegroundColor Green

        # 8. TRÁFICO DE RED
        Write-Host "`n🌐 ANALIZANDO TRÁFICO DE RED..." -ForegroundColor Yellow
        $fileNet = "C:\Temp\VMware_Reports\network_usage.csv"
        New-Item -Path $fileNet -ItemType File -Force | Out-Null
        Add-Content -Path $fileNet -Value "VM,AvgNetworkUsageGB"

        $networkData = @()
        foreach ($vm in $vms) {
            $netStats = Get-Stat -Entity $vm -Stat net.usage.average -Start $startDate -Finish $endDate
            if ($netStats) {
                $avgKBps = ($netStats | Measure-Object Value -Average).Average
                $avgGBMonth = [math]::Round((($avgKBps * 30 * 24 * 60 * 60) / 1GB), 2)
                Add-Content -Path $fileNet -Value "$($vm.Name),$avgGBMonth"
                $networkData += [PSCustomObject]@{
                    VM = $vm.Name
                    AvgNetworkUsageGB = $avgGBMonth
                }
            }
        }

        # Generar informe HTML - Red
        $htmlNet = @"
<!DOCTYPE html>
<html lang='es'>
<head>
    <meta charset='UTF-8'>
    <title>Informe de Red</title>
    <script src='https://cdn.jsdelivr.net/npm/chart.js'></script> 
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            text-align: center;
            padding: 20px;
        }
        .container {
            max-width: 900px;
            margin: auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.1);
        }
        canvas {
            height: 400px;
            margin-top: 20px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #007BFF;
            color: white;
        }
    </style>
</head>
<body>
<div class='container'>
    <h2>Uso de red mensual estimado (GB)</h2>
    <canvas id='networkChart'></canvas>
    <table>
        <thead><tr><th>VM</th><th>Promedio Uso (GB)</th></tr></thead>
        <tbody>
"@

        foreach ($row in $networkData) {
            $htmlNet += "<tr><td>$($row.VM)</td><td>$($row.AvgNetworkUsageGB)</td></tr>`n"
        }

        $htmlNet += @"

        </tbody>
    </table>
</div>

<script>
const netCtx = document.getElementById('networkChart').getContext('2d');
new Chart(netCtx, {
    type: 'bar',
    data: {
        labels: [`"@ + ($networkData.VM -join '","') + @""],
        datasets: [{
            label: 'Tráfico mensual estimado (GB)',
            data: [`"@ + ($networkData.AvgNetworkUsageGB -join ',') + @"],
            backgroundColor: 'rgba(76, 175, 80, 0.7)'
        }]
    },
    options: {
        responsive: true,
        scales: {
            y: {
                beginAtZero: true,
                ticks: {
                    callback: value => value + ' GB'
                }
            }
        }
    }
});
</script>

</body>
</html>
"@

        $htmlNet | Out-File "$reportFolder\network_usage_report.html" -Encoding UTF8
        Write-Host "✔️ Informe de tráfico de red generado." -ForegroundColor Green

        # 9. IOPS
        Write-Host "`n📊 ANALIZANDO IOPS..." -ForegroundColor Yellow
        $fileIOPS = "$reportFolder\Collect-IOPS.csv"
        New-Item -Path $fileIOPS -ItemType File -Force | Out-Null
        Add-Content -Path $fileIOPS -Value "TimeStamp,Cluster,VM,Disk,Datastore,ReadIOPS,WriteIOPS"

        function Collect-IOPS {
            $vms = Get-VM | Where-Object {
                $_.PowerState -eq "PoweredOn" -and $_.Name -notmatch "^vCLS"
            }

            $metrics = "virtualdisk.numberreadaveraged.average", "virtualdisk.numberwriteaveraged.average"
            $stats = Get-Stat -Realtime -Stat $metrics -Entity $vms -MaxSamples 1 -ErrorAction SilentlyContinue

            $hdTab = @{}
            foreach ($hd in Get-HardDisk -VM $vms) {
                $controllerKey = $hd.Extensiondata.ControllerKey
                $controller = $hd.Parent.Extensiondata.Config.Hardware.Device | Where-Object { $_.Key -eq $controllerKey }
                $hdTab["$($hd.Parent.Name)/scsi$($controller.BusNumber):$($hd.Extensiondata.UnitNumber)"] = $hd.FileName.Split(']')[0].TrimStart('[')
            }

            foreach ($stat in $stats) {
                $vmname = $stat.Entity.Name
                $cluster = Get-Cluster -VM $vmname -ErrorAction SilentlyContinue
                $line = "$($stat.Timestamp),$($cluster.Name),$vmname,$($stat.Instance),$($hdTab[$vmname + '/' + $stat.Instance]),$($stat.Value)"
                Add-Content -Path $fileIOPS -Value $line
            }
        }

        1..3 | ForEach-Object {
            Collect-IOPS
            Start-Sleep -Seconds 20
        }

        $iopsTableData = Import-Csv $fileIOPS | Group-Object VM | ForEach-Object {
            [PSCustomObject]@{
                VMName = $_.Name
                Cluster = ($_.Group | Select-Object -First 1).Cluster
                Datastore = ($_.Group | Select-Object -First 1).Datastore
                TotalReadIOPS = ($_.Group.ReadIOPS | Measure-Object -Sum).Sum
                TotalWriteIOPS = ($_.Group.WriteIOPS | Measure-Object -Sum).Sum
                TotalIOPS = [int]($_.TotalReadIOPS + $_.TotalWriteIOPS)
            }
        } | Sort-Object TotalIOPS -Descending

        # Generar informe HTML - IOPS
        $htmlIOPS = @"
<!DOCTYPE html>
<html lang='es'>
<head>
    <meta charset='UTF-8'>
    <title>Informe de IOPS</title>
    <script src='https://cdn.jsdelivr.net/npm/chart.js'></script> 
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            text-align: center;
            padding: 20px;
        }
        .container {
            max-width: 900px;
            margin: auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.1);
        }
        canvas {
            height: 400px;
            margin-top: 20px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th, td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #007BFF;
            color: white;
        }
    </style>
</head>
<body>
<div class='container'>
    <h2>IOPS Totales por Máquina Virtual</h2>
    <canvas id='iopsChart'></canvas>
    <table>
        <thead><tr><th>VM</th><th>Cluster</th><th>Datastore</th><th>Total IOPS</th></tr></thead>
        <tbody>
"@

        foreach ($row in $iopsTableData) {
            $htmlIOPS += "<tr><td>$($row.VMName)</td><td>$($row.Cluster)</td><td>$($row.Datastore)</td><td>$($row.TotalIOPS)</td></tr>`n"
        }

        $htmlIOPS += @"

        </tbody>
    </table>
</div>

<script>
const iopsCtx = document.getElementById('iopsChart').getContext('2d');
new Chart(iopsCtx, {
    type: 'bar',
    data: {
        labels: [`"@ + ($iopsTableData.VMName | Select-Object -First 10 | ForEach-Object {"`"$_`""}) -join "," + @""],
        datasets: [{
            label: 'Total IOPS',
            data: [`"@ + ($iopsTableData.TotalIOPS | Select-Object -First 10 | ForEach-Object {$_}) -join "," + @"],
            backgroundColor: 'rgba(54, 162, 235, 0.7)'
        }]
    },
    options: {
        responsive: true,
        scales: {
            y: {
                beginAtZero: true,
                ticks: {
                    callback: value => value + ' IOPS'
                }
            }
        }
    }
});
</script>

</body>
</html>
"@

        $htmlIOPS | Out-File "$reportFolder\vm_iops_report.html" -Encoding UTF8
        Write-Host "✔️ Informe de IOPS generado." -ForegroundColor Green

        # 10. DESCONECTAR DEL SERVIDOR
        Write-Host "`n🔌 DESCONECTANDO DE VCENTER..." -ForegroundColor Green
        Disconnect-VIServer -Confirm:$false

        Write-Host "`n✅ TODOS LOS INFORMES SE HAN GENERADO EN:" -ForegroundColor Green
        Write-Host "📁 $reportFolder" -ForegroundColor Cyan

        # Abrir automáticamente los informes
        Start-Process "$reportFolder\cpu_ready_report.html"
        Start-Process "$reportFolder\ram_usage_report.html"
        Start-Process "$reportFolder\network_usage_report.html"
        Start-Process "$reportFolder\vm_iops_report.html"

    } catch {
        Write-Host "❌ Error en la conexión: $_" -ForegroundColor Red
    }
}