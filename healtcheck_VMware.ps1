# Verificar e importar PowerCLI
Write-Host 'Verificando PowerCLI...' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Host 'PowerCLI no está instalado. Instalando...' -ForegroundColor Yellow
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
}
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Write-Host 'PowerCLI listo.' -ForegroundColor Green

# --- BLOQUE DE LIMPIEZA Y REINSTALACIÓN DE POWERCLI ---
Write-Host 'Verificando módulos de PowerCLI requeridos...' -ForegroundColor Cyan
$modulosRequeridos = @('VMware.VimAutomation.Core', 'VMware.VimAutomation.Common')
$modulosFaltantes = $modulosRequeridos | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($modulosFaltantes.Count -gt 0) {
    Write-Host 'Faltan módulos de PowerCLI o la instalación está corrupta. Procediendo a limpiar e instalar de nuevo...' -ForegroundColor Yellow
    # Intentar quitar módulos cargados
    Remove-Module VMware.* -ErrorAction SilentlyContinue
    # Eliminar módulos antiguos/corruptos
    Get-Module -ListAvailable VMware.* | ForEach-Object {
        try {
            Remove-Item -Recurse -Force $_.ModuleBase -ErrorAction Stop
            Write-Host "Módulo eliminado: $($_.Name)" -ForegroundColor DarkYellow
        } catch {
            Write-Host "No se pudo eliminar el módulo: $($_.Name)" -ForegroundColor Red
        }
    }
    # Reinstalar PowerCLI
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber
    Write-Host 'PowerCLI reinstalado.' -ForegroundColor Green
} else {
    Write-Host 'Todos los módulos requeridos de PowerCLI están presentes.' -ForegroundColor Green
}
# --- FIN BLOQUE LIMPIEZA ---

# Solicitar credenciales con popup
Write-Host 'Solicitando credenciales de vCenter/ESXi...' -ForegroundColor Cyan
$cred = Get-Credential -Message 'Introduce las credenciales de vCenter/ESXi'

# Valores por defecto
$directorioDefecto = "$HOME\ReportesVMware"
$reporteHtmlDefecto = "reporte_vmware.html"

# Solicitar datos de conexión y nombre del archivo HTML y directorio (con valores por defecto)
$vcHost = Read-Host 'vCenter/ESXi host'
$directorio = Read-Host "Directorio donde guardar el reporte (Enter para '$directorioDefecto')"
if ([string]::IsNullOrWhiteSpace($directorio)) { $directorio = $directorioDefecto }
$reporteHtml = Read-Host "Nombre del archivo HTML para el reporte (Enter para '$reporteHtmlDefecto')"
if ([string]::IsNullOrWhiteSpace($reporteHtml)) { $reporteHtml = $reporteHtmlDefecto }
$reportePath = Join-Path -Path $directorio -ChildPath $reporteHtml

# Crear el directorio si no existe
Write-Host "Verificando directorio de guardado: $directorio" -ForegroundColor Cyan
if (-not (Test-Path $directorio)) {
    Write-Host 'Directorio no existe. Creando...' -ForegroundColor Yellow
    New-Item -Path $directorio -ItemType Directory -Force | Out-Null
    Write-Host 'Directorio creado.' -ForegroundColor Green
} else {
    Write-Host 'Directorio existente.' -ForegroundColor Green
}

# Conectar a vCenter/ESXi
Write-Host "Conectando a vCenter/ESXi ($vcHost)..." -ForegroundColor Cyan
try {
    Connect-VIServer -Server $vcHost -Credential $cred -ErrorAction Stop | Out-Null
    Write-Host "Conexión exitosa a $vcHost" -ForegroundColor Green
} catch {
    Write-Host ('Error al conectar a ' + $vcHost + ': ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# Obtener todas las VMs, filtrando apagadas y las que empiezan por vcls
Write-Host 'Obteniendo lista de VMs encendidas (sin vcls)...' -ForegroundColor Cyan
$vms = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' -and -not ($_.Name -like 'vcls*') }
Write-Host "Se encontraron $($vms.Count) VMs encendidas (sin vcls)" -ForegroundColor Green

# Definir el rango de tiempo para las métricas (últimas 24 horas)
Write-Host 'Definiendo rango de tiempo para métricas (últimas 24 horas)...' -ForegroundColor Cyan
$end = Get-Date
$start = $end.AddHours(-24)

# Inicializar arrays para almacenar los datos
Write-Host 'Recolectando métricas de cada VM...' -ForegroundColor Cyan
$metricas = @()
$hayVmsSinIops = $false

foreach ($vm in $vms) {
    Write-Host "Procesando VM: $($vm.Name)" -ForegroundColor Gray
    # CPU Ready (en ms, sumado en 24h, convertido a porcentaje estimado)
    $cpuReady = (Get-Stat -Entity $vm -Stat cpu.ready.summation -Start $start -Finish $end | 
        Measure-Object -Property Value -Average).Average
    # RAM asignada (MB)
    $ramAsignada = $vm.MemoryMB
    # RAM consumida (MB, promedio en 24h)
    $ramConsumida = (Get-Stat -Entity $vm -Stat mem.usage.average -Start $start -Finish $end | 
        Measure-Object -Property Value -Average).Average * $vm.MemoryMB / 100
    # Consumo de red (KBps, promedio en 24h)
    $netUsage = (Get-Stat -Entity $vm -Stat net.usage.average -Start $start -Finish $end | 
        Measure-Object -Property Value -Average).Average
    # IOPS (manejar error si la métrica no existe)
    try {
        $iopsRead = (Get-Stat -Entity $vm -Stat disk.numberRead.summation -Start $start -Finish $end -ErrorAction Stop | 
            Measure-Object -Property Value -Average).Average
    } catch {
        $iopsRead = 0
        $hayVmsSinIops = $true
    }
    try {
        $iopsWrite = (Get-Stat -Entity $vm -Stat disk.numberWrite.summation -Start $start -Finish $end -ErrorAction Stop | 
            Measure-Object -Property Value -Average).Average
    } catch {
        $iopsWrite = 0
        $hayVmsSinIops = $true
    }
    $iops = $iopsRead + $iopsWrite
    $metricas += [PSCustomObject]@{
        VM = $vm.Name
        CPUReady = [math]::Round($cpuReady,2)
        RAM_Asignada = [math]::Round($ramAsignada,2)
        RAM_Consumida = [math]::Round($ramConsumida,2)
        NetUsage = [math]::Round($netUsage,2)
        IOPS = [math]::Round($iops,2)
    }
}

if ($hayVmsSinIops) {
    Write-Host "Advertencia: Una o más VMs no tienen disponible la métrica de IOPS. Se mostrará como 0 en el informe." -ForegroundColor Yellow
}

# Top 10 de cada métrica
Write-Host 'Calculando top 10 de cada métrica...' -ForegroundColor Cyan
$topCPU = $metricas | Sort-Object -Property CPUReady -Descending | Select-Object -First 10
$topRAMAsignada = $metricas | Sort-Object -Property RAM_Asignada -Descending | Select-Object -First 10
$topRAMConsumida = $metricas | Sort-Object -Property RAM_Consumida -Descending | Select-Object -First 10
$topNet = $metricas | Sort-Object -Property NetUsage -Descending | Select-Object -First 10
$topIOPS = $metricas | Sort-Object -Property IOPS -Descending | Select-Object -First 10

# Preparar datos para las gráficas en formato JS
function Get-ChartLabels { param($coleccion) '[' + ($coleccion | ForEach-Object { '"' + $_.VM + '"' }) -join ',' + ']' }
function Get-ChartData { param($coleccion, $col) '[' + ($coleccion | ForEach-Object { $_.$col }) -join ',' + ']' }

$cpuLabels = Get-ChartLabels $topCPU
$cpuData = Get-ChartData $topCPU 'CPUReady'
$ramAsignadaLabels = Get-ChartLabels $topRAMAsignada
$ramAsignadaData = Get-ChartData $topRAMAsignada 'RAM_Asignada'
$ramConsumidaLabels = Get-ChartLabels $topRAMConsumida
$ramConsumidaData = Get-ChartData $topRAMConsumida 'RAM_Consumida'
$netLabels = Get-ChartLabels $topNet
$netData = Get-ChartData $topNet 'NetUsage'
$iopsLabels = Get-ChartLabels $topIOPS
$iopsData = Get-ChartData $topIOPS 'IOPS'

# Generar HTML
Write-Host 'Generando reporte HTML...' -ForegroundColor Cyan

function Generar-TablaHtml($titulo, $coleccion, $col1, $col2) {
    $tabla = "<h2>$titulo</h2>"
    $tabla += "<table border='1' style='border-collapse:collapse;'><tr><th>VM</th><th>$col2</th></tr>"
    foreach ($item in $coleccion) {
        $tabla += "<tr><td>$($item.VM)</td><td>$($item.$col2)</td></tr>"
    }
    $tabla += "</table>"
    return $tabla
}

$html = @"
<html>
<head>
<title>Healthcheck VMware</title>
<script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
<style>
    body { font-family: Arial, Helvetica, sans-serif; background: #fafbfc; margin: 0; padding: 0; }
    h1 { color: #222; margin-top: 30px; text-align: center; }
    h2 { color: #1a4e8a; margin-top: 40px; }
    p { color: #444; text-align: center; }
    table { margin: 20px auto 40px auto; border-collapse: collapse; min-width: 350px; box-shadow: 0 2px 8px #e0e0e0; background: #fff; }
    th, td { padding: 10px 18px; border: 1px solid #bfc9d1; text-align: center; }
    th { background: #1976d2; color: #fff; font-weight: bold; }
    tr:nth-child(even) { background: #f4f8fb; }
    tr:hover { background: #e3f2fd; }
    canvas { display: block; margin: 0 auto 40px auto; max-width: 700px; max-height: 350px; background: #fff; border-radius: 8px; box-shadow: 0 2px 8px #e0e0e0; }
</style>
</head>
<body>
<h1>Reporte Healthcheck VMware</h1>
<p>Generado el $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>

$(Generar-TablaHtml 'Top 10 CPU Ready (ms)' $topCPU 'VM' 'CPUReady')
<canvas id='cpuChart'></canvas>

$(Generar-TablaHtml 'Top 10 RAM Asignada (MB)' $topRAMAsignada 'VM' 'RAM_Asignada')
<canvas id='ramAsignadaChart'></canvas>

$(Generar-TablaHtml 'Top 10 RAM Consumida (MB)' $topRAMConsumida 'VM' 'RAM_Consumida')
<canvas id='ramConsumidaChart'></canvas>

$(Generar-TablaHtml 'Top 10 Consumo de Red (KBps)' $topNet 'VM' 'NetUsage')
<canvas id='netChart'></canvas>

$(Generar-TablaHtml 'Top 10 IOPS' $topIOPS 'VM' 'IOPS')
<canvas id='iopsChart'></canvas>

<script>
// Declarar los datos como variables JS
var cpuLabels = $cpuLabels;
var cpuData = $cpuData;
var ramAsignadaLabels = $ramAsignadaLabels;
var ramAsignadaData = $ramAsignadaData;
var ramConsumidaLabels = $ramConsumidaLabels;
var ramConsumidaData = $ramConsumidaData;
var netLabels = $netLabels;
var netData = $netData;
var iopsLabels = $iopsLabels;
var iopsData = $iopsData;

function crearGrafica(id, labels, data, label) {
    var ctx = document.getElementById(id);
    if (!ctx) return;
    new Chart(ctx, {
        type: 'bar',
        data: {
            labels: labels,
            datasets: [{
                label: label,
                data: data,
                backgroundColor: 'rgba(54, 162, 235, 0.5)',
                borderColor: 'rgba(54, 162, 235, 1)',
                borderWidth: 1
            }]
        },
        options: {
            responsive: true,
            plugins: {
                legend: { display: false },
                title: { display: false }
            },
            scales: {
                x: { ticks: { color: '#222', font: { weight: 'bold' } } },
                y: { beginAtZero: true, ticks: { color: '#222' } }
            }
        }
    });
}

document.addEventListener('DOMContentLoaded', function() {
    crearGrafica('cpuChart', cpuLabels, cpuData, 'CPU Ready (ms)');
    crearGrafica('ramAsignadaChart', ramAsignadaLabels, ramAsignadaData, 'RAM Asignada (MB)');
    crearGrafica('ramConsumidaChart', ramConsumidaLabels, ramConsumidaData, 'RAM Consumida (MB)');
    crearGrafica('netChart', netLabels, netData, 'Consumo de Red (KBps)');
    crearGrafica('iopsChart', iopsLabels, iopsData, 'IOPS');
});
</script>
</body>
</html>
"@

# Guardar el HTML
Write-Host "Guardando reporte en: $reportePath" -ForegroundColor Cyan
Set-Content -Path $reportePath -Value $html -Encoding UTF8
Write-Host "Reporte generado: $reportePath" -ForegroundColor Green

# Abrir el HTML en el navegador predeterminado
Write-Host 'Abriendo el reporte en el navegador...' -ForegroundColor Cyan
try {
    Start-Process $reportePath
    Write-Host "Reporte abierto en el navegador." -ForegroundColor Green
} catch {
    Write-Host "No se pudo abrir el archivo automáticamente. Ábrelo manualmente en: $reportePath" -ForegroundColor Yellow
} 