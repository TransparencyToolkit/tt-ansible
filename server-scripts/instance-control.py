#!/usr/bin/env python3
# sudo apt install python3-pyinotify/testing


import pyinotify
import os.path
import subprocess
import re
import json
import _thread
import time

# the name of the template, and the "range".
# the range is used to generate a subnet like 10.13.{range}.x
# for the ArchiveAdministrator belonging to the template
TEMPLATE_NAME = "next"
TEMPLATE_RANGE= "1"

INTERNAL_DOMAIN = 'demo.transparency.tools'
# ^-- domain for archiveVMs

PUBLIC_DOMAIN = 'transparency.tools'
# ^-- public subdomains will be added under this domain

AA_IP = f'10.13.{TEMPLATE_RANGE}.2'
# ip of archiveadministrator instance

# directory storing configuration files produced by ArchiveAdministrator:
CONFIG_DIR='/tt_archive_config' # NB: without trailing slash!

# directory storing OCR files:
OCR_DIR='/tt_ocr/' # NB: without trailing slash!
OCR_DIR_LEN = len(OCR_DIR.split('/'))-1

# number of seconds of inactivity to wait before shutting down the
# OCR VM belonging to an archive:
OCR_TIMEOUT_SECONDS = 60 * 60

OCR_TIMERS = {}

def ocr_timeout(*_):
    '''Shutdown OCR VMs after a timeout of no activity for 15 minutes'''
    while True:
        try:
            time.sleep(10)
            current_time = time.time()
            for instance, last_seen in list(OCR_TIMERS.items()):
                kill_in = last_seen + OCR_TIMEOUT_SECONDS - current_time
                if kill_in <= 0:
                    print('*/* shutting down', instance,
                          ' OCR VM due to inactivity')
                    vm_shutdown('', instance, '_ocr', validation=False)
        except Exception as e:
            print('OCR_TIMEOUT: Exception!', e)

def validate_instance_name(name):
    if len(name) and re.match(r'\A[a-z][a-z_0-9]+\Z', name): return
    raise Exception('Invalid instance name: %s' % (name))

def validate_subdomain(name):
    if len(name) and re.match(r'\A[a-z][a-z.0-9-]+\Z', name): return
    raise Exception('Invalid subdomain: %s' % (name))

def get_configs(suffix=''):
    from os import listdir
    ret = []
    instance_names = filter(lambda n: 'control' != n, listdir(CONFIG_DIR))
    instances = [(n, CONFIG_DIR+'/'+n+suffix) for n in instance_names]
    for name, i_path in filter(lambda np: os.path.isdir(np[1]), instances):
        config = i_path + '/ip_config.json'
        if not os.path.isfile(config): continue
        with open(config,'r') as fh: ips = json.load(fh)
        if not ips.get('SUBDOMAIN', False):
            print('get_configs(): ignoring old domain config:', i_path)
            continue
        ips['instance'] = name
        ret.append(ips)
    return ret
def get_private_configs():
    return get_configs('')
def get_public_configs():
    return get_configs('/public')

def nginx_ssl_block(domain):
    return f'''
        ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem; # managed by Certbot
        ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem; # managed by Certbot
    '''

def nginx_config_subdomain(subdomain, gateway_ip, public_ip):
    '''Configure public LG nginx block in /etc/nginx/sites-enabled/INSTANCE'''

    validate_subdomain(subdomain)
    subdomain_block = f'''
    server {{
        listen 443 ssl;
        listen [::]:443 ssl;
        client_max_body_size 10G;
        root /var/www/html;
        index index.html index.htm;
        server_name {subdomain}.transparency.tools;

        location / {{
           proxy_connect_timeout 300; proxy_send_timeout 300;
           proxy_read_timeout 300;    send_timeout 300;
           proxy_redirect $scheme://$host:$server_port/ /;
           proxy_set_header Host {subdomain}.transparency.tools;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_buffer_size 8k; proxy_buffers 32 8k;
           proxy_buffering off;
           #proxy_bind {gateway_ip};
           proxy_pass http://{public_ip}:3001/;
        }}
    }}
    '''

    print('nginx config public block (/etc/nginx/sites-enabled/%s):\n%s\n\n' % (
        subdomain, subdomain_block))
    with open('/etc/nginx/sites-enabled/'+subdomain, 'w') as fh: # TODO 'x'
        # ^-- write+creat+excl
        fh.write(subdomain_block)

def nginx_config_internals(subdomain, gateway_ip, internal_ip, ssl_block):
    validate_subdomain(subdomain)
    shared_block = f'''
    location ^~ /{subdomain}/upload/ {{
        proxy_connect_timeout 300; proxy_send_timeout 300;
        proxy_read_timeout 300;    send_timeout 300;
        proxy_set_header Origin $scheme://$host;
        proxy_set_header Connection $http_connection;
        proxy_set_header X-Forwarded-Protocol $scheme;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Ssl on;
        proxy_set_header Host {INTERNAL_DOMAIN};
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffer_size 8k; proxy_buffers 32 8k;
        proxy_buffering off;
        proxy_bind {gateway_ip};
        #rewrite ^/{subdomain}/upload(.*) /$1 break;
        proxy_pass http://{internal_ip}:9292/;
    }}
    location ^~ /{subdomain}/lookingglass/ {{
        proxy_connect_timeout 300; proxy_send_timeout 300;
        proxy_read_timeout 300; send_timeout 300;
        proxy_set_header Origin $scheme://$host;
        proxy_set_header Connection $http_connection;
        proxy_set_header X-Forwarded-Protocol $scheme;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Ssl on;
        proxy_set_header Host {INTERNAL_DOMAIN};
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
        proxy_buffer_size 8k; proxy_buffers 32 8k;
        proxy_bind {gateway_ip};
        rewrite ^/{subdomain}/lookingglass/({subdomain}/lookingglass.*) /$1 break;
        rewrite ^/(.*) /$1 break;
        proxy_pass http://{internal_ip}:3001/;
    }}
    '''
    return shared_block

def nginx_shared_header(skip_vm=''):
    '''writes the shared tt-internal site for nginx, and returns the current subdomaisn
    '''
    shared_block = f'''
    server {{
      listen 80 default_server;
      location /.well-known/acme-challenge {{
        root        /var/www/html;
      }}
      location / {{
        if ($scheme = http) {{
            return 301 https://$host$request_uri;
        }}
      }}
    }}
    server {{
        listen 443 ssl default_server;
        listen [::]:443 ssl default_server;

        client_max_body_size 10G;
        root /var/www/html;
        index index.html index.htm;
        server_name {INTERNAL_DOMAIN};

        # Redirect to ArchiveAdministrator
        location ^~ / {{
          proxy_connect_timeout 300; proxy_send_timeout 300;
          proxy_read_timeout 300;    send_timeout 300;
          proxy_set_header Origin $scheme://$host;
          proxy_set_header Connection $http_connection;
          proxy_set_header X-Forwarded-Protocol $scheme;
          proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header    X-Forwarded-Ssl on;
          proxy_set_header Host {INTERNAL_DOMAIN};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_buffer_size 8k; proxy_buffers 32 8k;
          proxy_buffering off;
          rewrite ^/(.*) /$1 break;
          proxy_pass http://{AA_IP}:3002/;
        }}
    '''
    shared_block += nginx_ssl_block(INTERNAL_DOMAIN)

    confs = get_private_configs()
    for sub in confs:
        ssl_block = not (sub['SUBDOMAIN'] == skip_vm)
        shared_block += nginx_config_internals(sub['SUBDOMAIN'],
                                               sub['ARCHIVE_GATEWAY_IP'],
                                               sub['ARCHIVE_VM_IP'],
                                               ssl_block=ssl_block)
    shared_block += '\n} # end server block\n'

    print(f'nginx config shared block (/etc/nginx/sites-enabled/tt-internal):\
    \n{shared_block}\n\n')

    with open('/etc/nginx/sites-enabled/tt-internal','w') as fh:
        fh.write(shared_block)


def nginx_remove_subdomain(subdomain):
    validate_subdomain(subdomain)
    pass

def delete_instance(instance, validation=True):
    if validation:
        validate_instance_name(instance)
    # remove from nginx too:
    with open(f'{CONFIG_DIR}/{instance}/ip_config.json') as fh:
        conf = json.load(fh)

    vm_shutdown('', instance, '')

    rm_conf = ['rm','-r','--',CONFIG_DIR+'/'+instance]
    print(*rm_conf)

    nuke = ['/root/nuke-instance.sh', instance]
    print(*nuke)
    subprocess.call(nuke)

    rm_ng = ['rm','--','/etc/nginx/sites-enabled/'+conf['SUBDOMAIN']]
    print(*rm_ng)
    subprocess.call(rm_ng)

    # and from letsencrypt certbot
    rm_lets = ['certbot','-n','delete','--cert-name',
               conf['SUBDOMAIN'] +'.'+ PUBLIC_DOMAIN]
    print(*rm_lets)
    subprocess.call(rm_lets)

    nginx_shared_header()

    nginx = ['systemctl','reload','nginx']
    print(*nginx)
    subprocess.call(nginx)

def new_mac_addr():
    '''returns a colon-separated MAC address prefix with 52:54:00 which
       is the prefix required by KVM for KVM VMs'''
    with open('/dev/urandom','rb') as fh:
        mac = ':'.join(['52','54','00',
                        fh.read(1).hex(),
                        fh.read(1).hex(),
                        fh.read(1).hex()])
    return mac

def new_private_instance(instance, ips):
    '''Creates a new archive instance, setting up redirects on
       the internal host'''
    subdomain = ips['SUBDOMAIN']
    gw_ip = ips['ARCHIVE_GATEWAY_IP']
    vm_ip = ips['ARCHIVE_VM_IP']
    nginx_shared_header(skip_vm=ips['SUBDOMAIN'])
    # renew existing certs already configured:
    certbot_renew = ['certbot','-n','--nginx','renew']
    print(*certbot_renew)
    subprocess.call(certbot_renew)

    nginx = ['systemctl','reload','nginx']
    print(*nginx)
    subprocess.call(nginx)

    cmd = ['/root/generate-instance.sh', instance, gw_ip, vm_ip,
           new_mac_addr(), TEMPLATE_NAME, TEMPLATE_RANGE]

    OCR_TIMERS[instance] = time.time()

    return cmd

def new_public_instance(instance, ips):
    '''Makes a new public instance for LG, allocating a subdomain'''
    subdomain  = ips['SUBDOMAIN']
    gateway_ip = ips['PUBLIC_GATEWAY_IP']
    public_ip  = ips['PUBLIC_VM_IP']
    archive_ip = ips.get('ARCHIVE_VM_IP')
    try:
        if not archive_ip:
            private = list(filter(lambda o: o['instance']==instance,
                                  get_private_configs()))
            assert (1 == len(private))
            archive_ip = private[0]['ARCHIVE_VM_IP']

        nginx_config_subdomain(subdomain, gateway_ip, public_ip)
        # get a SSL cert:
        certbot = ['certbot','-n','--nginx', '-d', subdomain + '.' + PUBLIC_DOMAIN]
        print(*certbot)
        assert (0 == subprocess.call(certbot))
        nginx = ['systemctl','reload','nginx']
        print(*nginx)
        assert (0 == subprocess.call(nginx))

        return ['/root/generate-public-instance.sh',
                instance, gateway_ip, public_ip, new_mac_addr(),
                archive_ip, TEMPLATE_NAME, TEMPLATE_RANGE]
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        print('creating public vm failed', e, tb)
        c = ['rm','-f','/etc/nginx/sites-enabled/'+instance]
        print(*c)
        subprocess.call(c)
        c = ['rm','-rf', CONFIG_DIR+'/'+instance+'/public/']
        print(*c)
        subprocess.call(c)
        c = ['/root/nuke-instance.sh', 'pub-'+instance]
        print(*c)

        subprocess.call(c)
        nginx_shared_header()
        nginx = ['systemctl','reload','nginx']
        print(*nginx)
        subprocess.call(nginx)
        raise e

def vm_start(prefix, instance, suffix=''):
    cmd=['virsh','start', '--', f'vm-{prefix}{instance}{suffix}']
    print(*cmd)
    # TODO handle errors:
    subprocess.call(cmd)
    if '_ocr' == suffix:
        OCR_TIMERS[instance] = time.time()

def vm_shutdown(prefix, instance, suffix='', validation=True):
    validation and validate_instance_name(instance)
    try: del OCR_TIMERS[instance]
    except KeyError: pass
    cmd = ['virsh','shutdown','--', f'vm-{prefix}{instance}{suffix}']
    print(*cmd)
    subprocess.call(cmd)

class EventHandler(pyinotify.ProcessEvent):

    def created_file(self, event):
        if event.path.startswith(OCR_DIR):
            print('got OCR event', event)
        elif CONFIG_DIR + '/control' == event.path:
            kind, instance = event.name.split('_', 1)
            validate_instance_name(instance)
            if 'shutdown' == kind:
                vm_shutdown('', instance)
            elif 'start' == kind:
                vm_start('',instance)
                vm_start('pub-', instance)
            elif 'delete' == kind:
                delete_instance(instance)
            else:
                raise Exception('unknown command: %s from instance %s' % (
                    kind,instance))
            # we understood the command:
            cmd=['rm','--',event.pathname]
            print(*cmd)
            assert (0 == subprocess.call(cmd))
        else:
            print('a file was made %s in %s' % (event.name, event.path))

    def process_IN_CREATE(self, event):
        try:
            if event.path.startswith(CONFIG_DIR) and not event.dir:
                self.created_file(event)
        except Exception as e:
            import traceback
            tb = traceback.format_exc()
            print('oops! ', e, tb)
        print('------- creating:', event.pathname)

    def maybe_generate_instance(self, event):
        if 'ip_config.json' == event.name:
            import time
            time.sleep(0.5) # yeah, inotify..
            ips = json.load(open(event.pathname))
            instance_type = ips.get("TYPE")

            print(f'>>>> got new VM {instance_type}: {ips}')

            if 'publicvm' == instance_type:
                instance = os.path.basename(os.path.dirname(event.path))
                cmd = new_public_instance(instance, ips)
            elif 'internalvm' == instance_type:
                instance = os.path.basename(event.path)
                cmd = new_private_instance(instance, ips)
            else:
                raise Exception(f"unknown instance type {instance} {ips}")

            print(*cmd)
            if 0 == subprocess.call(cmd):
                print('ALL GOOD: ',*cmd)
            else:
                raise Exception(f'VM {instance} creation failed: {ips}')

    def ocr_extract_instance(self, event):
        components = event.path.split('/')[OCR_DIR_LEN:]
        if components[0].endswith('_in'):
            return components[0][:-len('_in')]
        elif components[0].endswith('_out'):
            return components[0][:-len('_out')]

    def ocr_update_timer(self, event):
        '''Updates the timeout'''
        instance = self.ocr_extract_instance(event)
        if instance:
            if instance.startswith('vm-pub-'):
                instance = instance[len('vm-pub-'):]
            validate_instance_name(instance)
            # register last seen activity:
            OCR_TIMERS[instance] = time.time()

    def handle_ocr(self,event):
        components = event.path.split('/')[OCR_DIR_LEN:]
        if components[0].endswith('_in'):
            instance = components[0][:-len('_in')]
            if 'metadata' == components[1] and event.name.endswith('.json'):
                # only start the OCR vm once we have a .json file with the
                # metadata produced by DocUpload once it's done uploading:
                vm_start('', instance, '_ocr')
        else:
            # register that we saw activity:
            self.ocr_update_timer(event)

    def process_IN_MODIFY(self, event):
        '''Update OCR timeout when a file was written to'''
        if event.path.startswith(OCR_DIR):
            self.ocr_update_timer(event)

    def process_IN_CLOSE_WRITE(self, event):
        try:
            print('maybe close-write', event)
            if event.path.startswith(CONFIG_DIR):
                self.maybe_generate_instance(event)
            elif event.path.startswith(OCR_DIR):
                self.handle_ocr(event)
        except Exception as e:
            import traceback
            tb = traceback.format_exc()
            print('IN_CLOSE_WRITE: Exception! ', e, tb)

wm = pyinotify.WatchManager()
notifier = pyinotify.Notifier(wm, EventHandler())

wm.add_watch(CONFIG_DIR,
             # https://github.com/seb-m/pyinotify/wiki/Events-types
             pyinotify.IN_DONT_FOLLOW |
             pyinotify.IN_CLOSE_WRITE | # pick up vm config file
             pyinotify.IN_CREATE |      # pick up control/ touches
             pyinotify.IN_ONLYDIR,
             rec=True, auto_add=True)
wm.add_watch(OCR_DIR,
             pyinotify.IN_DONT_FOLLOW |
             pyinotify.IN_CLOSE_WRITE |
             pyinotify.IN_CREATE |
             pyinotify.IN_MODIFY |
             pyinotify.IN_ONLYDIR,
             rec=True, auto_add=True)

# Run OCR VM timeout thread that will kill OCR VMs after period of inactivity:
_thread.start_new_thread(ocr_timeout, ('ocr timeout thread', 2))

# Start all known VMs (except OCR since they will be launched on demand):
for vm in get_configs():
    vm_start('', vm['instance'], '')
    vm_start('pub-', vm['instance'])

notifier.loop()
