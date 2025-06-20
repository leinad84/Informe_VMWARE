# Solicitar datos de conexión y nombre del archivo HTML
$vcHost = Read-Host 'vCenter/ESXi host'
$vcUser = Read-Host 'Usuario'
$vcPass = Read-Host 'Contraseña' -AsSecureString
$reporteHtml = Read-Host 'Nombre del archivo HTML para el reporte (ej: reporte_vmware.html)'

# Conectar a vCenter/ESXi
try {
    Connect-VIServer -Server $vcHost -User $vcUser -Password $vcPass -ErrorAction Stop | Out-Null
    Write-Host "Conexión exitosa a $vcHost" -ForegroundColor Green
} catch {
    Write-Host ('Error al conectar a ' + $vcHost + ': ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# Obtener todas las VMs, filtrando apagadas y las que empiezan por vcls
$vms = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' -and -not ($_.Name -like 'vcls*') }
Write-Host "Se encontraron $($vms.Count) VMs encendidas (sin vcls)"

# Definir el rango de tiempo para las métricas (últimas 24 horas)
$end = Get-Date
$start = $end.AddHours(-24)

# Inicializar arrays para almacenar los datos
$metricas = @()

foreach ($vm in $vms) {
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
    # IOPS (suma de lecturas y escrituras en 24h, promedio)
    $iopsRead = (Get-Stat -Entity $vm -Stat disk.numberRead.summation -Start $start -Finish $end | 
        Measure-Object -Property Value -Average).Average
    $iopsWrite = (Get-Stat -Entity $vm -Stat disk.numberWrite.summation -Start $start -Finish $end | 
        Measure-Object -Property Value -Average).Average
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

# Top 10 de cada métrica
$topCPU = $metricas | Sort-Object -Property CPUReady -Descending | Select-Object -First 10
$topRAMAsignada = $metricas | Sort-Object -Property RAM_Asignada -Descending | Select-Object -First 10
$topRAMConsumida = $metricas | Sort-Object -Property RAM_Consumida -Descending | Select-Object -First 10
$topNet = $metricas | Sort-Object -Property NetUsage -Descending | Select-Object -First 10
$topIOPS = $metricas | Sort-Object -Property IOPS -Descending | Select-Object -First 10

# Función para generar tabla HTML
function Generar-TablaHtml($titulo, $coleccion, $col1, $col2) {
    $tabla = "<h2>$titulo</h2>"
    $tabla += "<table border='1' style='border-collapse:collapse;'><tr><th>VM</th><th>$col2</th></tr>"
    foreach ($item in $coleccion) {
        $tabla += "<tr><td>$($item.VM)</td><td>$($item.$col2)</td></tr>"
    }
    $tabla += "</table>"
    return $tabla
}

# Función para generar datos de gráfica para Chart.js
function Generar-ChartData($coleccion, $col2) {
    $labels = ($coleccion | ForEach-Object { '"' + $_.VM + '"' }) -join ','
    $data = ($coleccion | ForEach-Object { $_.$col2 }) -join ','
    return @{labels=$labels; data=$data}
}

# Generar HTML
$html = @"
<html>
<head>
<title>Healthcheck VMware</title>
<script src='https://cdn.jsdelivr.net/npm/chart.js'></script>
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
function crearGrafica(id, labels, data, label) {
    new Chart(document.getElementById(id), {
        type: 'bar',
        data: {
            labels: [labels],
            datasets: [{
                label: label,
                data: [data],
                backgroundColor: 'rgba(54, 162, 235, 0.5)'
            }]
        },
        options: {responsive:true, plugins:{legend:{display:false}}}
    });
}
$(
    crearGrafica('cpuChart', $((Generar-ChartData $topCPU 'CPUReady').labels), $((Generar-ChartData $topCPU 'CPUReady').data), 'CPU Ready (ms)');
    crearGrafica('ramAsignadaChart', $((Generar-ChartData $topRAMAsignada 'RAM_Asignada').labels), $((Generar-ChartData $topRAMAsignada 'RAM_Asignada').data), 'RAM Asignada (MB)');
    crearGrafica('ramConsumidaChart', $((Generar-ChartData $topRAMConsumida 'RAM_Consumida').labels), $((Generar-ChartData $topRAMConsumida 'RAM_Consumida').data), 'RAM Consumida (MB)');
    crearGrafica('netChart', $((Generar-ChartData $topNet 'NetUsage').labels), $((Generar-ChartData $topNet 'NetUsage').data), 'Consumo de Red (KBps)');
    crearGrafica('iopsChart', $((Generar-ChartData $topIOPS 'IOPS').labels), $((Generar-ChartData $topIOPS 'IOPS').data), 'IOPS');
)
</script>
</body>
</html>
"@

# Guardar el HTML
Set-Content -Path $reporteHtml -Value $html -Encoding UTF8
Write-Host "Reporte generado: $reporteHtml" -ForegroundColor Green 