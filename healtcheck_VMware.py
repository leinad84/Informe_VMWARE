# NOTA: El usuario ha solicitado migrar el script a PowerShell. El desarrollo continuará en un archivo .ps1
# Este archivo ya no se usará para el script principal.

import ssl
import atexit
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim
import pandas as pd
import matplotlib.pyplot as plt
from jinja2 import Environment, FileSystemLoader
import getpass

# Configuración de conexión
VCENTER_HOST = input('vCenter/ESXi host: ')
VCENTER_USER = input('Usuario: ')
VCENTER_PASSWORD = getpass.getpass('Contraseña: ')
REPORTE_HTML = input('Nombre del archivo HTML para el reporte (ej: reporte_vmware.html): ')

# Ignorar certificados SSL
context = ssl._create_unverified_context()

# Conexión
si = SmartConnect(host=VCENTER_HOST, user=VCENTER_USER, pwd=VCENTER_PASSWORD, sslContext=context)
atexit.register(Disconnect, si)

content = si.RetrieveContent()

# Función para obtener todas las VMs

def get_all_vms(content):
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
    vms = container.view
    container.Destroy()
    return vms

# Filtrar VMs apagadas y que empiezan por vcls

def filtrar_vms(vms):
    return [vm for vm in vms if vm.runtime.powerState == 'poweredOn' and not vm.name.lower().startswith('vcls')]

# Función para recolectar métricas de cada VM

def recolectar_metricas(vm):
    summary = vm.summary
    stats = {}
    stats['name'] = vm.name
    # CPU Ready (en ms, requiere performance manager para precisión, aquí solo ejemplo)
    stats['cpu_ready'] = getattr(summary.quickStats, 'overallCpuLatency', 0)
    # RAM asignada y consumida (MB)
    stats['ram_asignada'] = getattr(summary.config, 'memorySizeMB', 0)
    stats['ram_consumida'] = getattr(summary.quickStats, 'guestMemoryUsage', 0)
    # Consumo de red (KBps)
    stats['net_usage'] = getattr(summary.quickStats, 'overallNetworkUsage', 0)
    # IOPS (requiere performance manager, aquí solo ejemplo con diskUsage)
    stats['iops'] = getattr(summary.quickStats, 'overallDiskUsage', 0)
    return stats

# Punto de entrada principal

def main():
    vms = get_all_vms(content)
    vms_filtradas = filtrar_vms(vms)
    print(f'Se encontraron {len(vms_filtradas)} VMs encendidas (sin vcls)')
    # Recolectar métricas
    metricas = [recolectar_metricas(vm) for vm in vms_filtradas]
    df = pd.DataFrame(metricas)
    # Top 10 por cada métrica
    top_cpu = df.sort_values('cpu_ready', ascending=False).head(10)
    top_ram_asignada = df.sort_values('ram_asignada', ascending=False).head(10)
    top_ram_consumida = df.sort_values('ram_consumida', ascending=False).head(10)
    top_net = df.sort_values('net_usage', ascending=False).head(10)
    top_iops = df.sort_values('iops', ascending=False).head(10)
    # Generar reporte HTML (pendiente de implementar)
    # ...

if __name__ == '__main__':
    main()
