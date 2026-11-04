#!/usr/bin/env python3
# r445 仪器144：**软件 DLNA/UPnP 渲染器**（MediaRenderer:1），跑在宿主 Mac 上，
# 用来把 `docs/android-remaining-todo-r418.md` §一 #2「音频 DLNA 投屏正支」那条
# 「同一 LAN 里开一个 DLNA 设备（电视/音箱/**软件渲染器**）」的条件**自己造出来**。
#
# 背景（r415 读数）：`RemotePlayer::list` 三版成功回 `{"players": []}` ＋ 同网段 SSDP 零渲染器
# ⇒ 之前定性"结构性不可得"。但投屏目标列表是 **NAS 侧**发现的（`SYNO.AudioStation.RemotePlayer.list`），
# 所以只要同网段出现一个**能被 NAS 发现**的 MediaRenderer，这条路就能真机验。
#
# 用法：
#   python3 tool/r445_upnp_renderer.py --log /tmp/r445/renderer.log [--port 49494] [--name "r445 Test Renderer"]
#   （Ctrl-C 退出时会发 ssdp:byebye）
#
# 只做三件事：① SSDP 应答/通告；② 提供设备描述与 SCPD；③ 收 SOAP 动作并**逐条记账**
# （谁在什么时候调了什么，请求体原文）—— 记账本身就是本轮的真机证据：
# 「App 把曲目推到该设备」到底变成了 NAS 上的哪些动词。
#
# 不依赖任何第三方库（stdlib 即可），不碰 NAS 上任何数据（本进程只被动收包）。
import argparse
import http.server
import json
import os
import re
import socket
import socketserver
import struct
import sys
import threading
import time
import urllib.request
import uuid

DLNA_SINK = (
    'http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000,'
    'http-get:*:audio/mp4:DLNA.ORG_PN=AAC_ISO_320;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000,'
    'http-get:*:audio/x-flac:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000,'
    'http-get:*:audio/L16;rate=44100;channels=2:DLNA.ORG_PN=LPCM;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000,'
    'http-get:*:audio/*:*')
SSDP_ADDR = '239.255.255.250'
SSDP_PORT = 1900
DEVICE_TYPE = 'urn:schemas-upnp-org:device:MediaRenderer:1'
SERVICE_TYPES = [
    'urn:schemas-upnp-org:service:AVTransport:1',
    'urn:schemas-upnp-org:service:RenderingControl:1',
    'urn:schemas-upnp-org:service:ConnectionManager:1',
]

SUBS = {}  # sid -> (callback_url, service_short)
SEQ = {}

STATE = {
    'transport': 'STOPPED',
    'uri': '',
    'metadata': '',
    'volume': 50,
    'mute': 0,
}
LOG_LOCK = threading.Lock()
LOG_PATH = None


def log(kind, line):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    out = f'[{ts}] {kind} {line}'
    with LOG_LOCK:
        print(out, flush=True)
        if LOG_PATH:
            with open(LOG_PATH, 'a', encoding='utf-8') as f:
                f.write(out + '\n')


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('192.168.0.1', 80))
        return s.getsockname()[0]
    finally:
        s.close()


VARIANT = 'basic'


class Cfg:
    ip = None
    port = 49494
    name = 'r445 Test Renderer'
    udn = 'uuid:' + str(uuid.uuid4())


def service_types():
    '''变体 C：把三个服务都升到 v2（有些控制点只认 v2）。'''
    if VARIANT in ('v2', 'v2canon'):
        return [t.replace(':1', ':2') for t in SERVICE_TYPES]
    return list(SERVICE_TYPES)


def root_desc():
    services = []
    for st in service_types():
        short = st.split(':')[3]
        sid = (f'urn:upnp-org:serviceId:{short}'
               if VARIANT in ('canonical', 'v2canon', 'dlna', 'urlbase')
               else short)
        services.append(
            f'''<service>
<serviceType>{st}</serviceType>
<serviceId>{sid}</serviceId>
<SCPDURL>/{short}.xml</SCPDURL>
<controlURL>/{short}/control</controlURL>
<eventSubURL>/{short}/event</eventSubURL>
</service>'''
        )
    return f'''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<device>
{'<URLBase>http://%s:%d/</URLBase>' % (Cfg.ip, Cfg.port) if VARIANT in ('urlbase', 'v2canon') else ''}
<deviceType>{DEVICE_TYPE}</deviceType>
<friendlyName>{Cfg.name}</friendlyName>
<manufacturer>SynHub</manufacturer>
<manufacturerURL>https://example.invalid/</manufacturerURL>
<modelDescription>r445 software DLNA renderer (test fixture)</modelDescription>
<modelName>r445-renderer</modelName>
<modelNumber>1</modelNumber>
<UDN>{Cfg.udn}</UDN>
<dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>
<serviceList>
{''.join(services)}
</serviceList>
</device>
</root>'''


def _scpd(actions, state_vars):
    parts = ['<?xml version="1.0"?>',
             '<scpd xmlns="urn:schemas-upnp-org:service-1-0">',
             '<specVersion><major>1</major><minor>0</minor></specVersion>',
             '<actionList>']
    for name, args in actions:
        parts.append(f'<action><name>{name}</name>')
        parts.append('<argumentList>')
        for an, direction, sv in args:
            parts.append(f'<argument><name>{an}</name><direction>{direction}</direction>'
                         f'<relatedStateVariable>{sv}</relatedStateVariable></argument>')
        parts.append('</argumentList></action>')
    parts.append('</actionList><serviceStateTable>')
    for name, dtype, send in state_vars:
        parts.append(f'<stateVariable sendEvents="{send}"><name>{name}</name>'
                     f'<dataType>{dtype}</dataType></stateVariable>')
    parts.append('</serviceStateTable></scpd>')
    return '\n'.join(parts)


_IN = [('InstanceID', 'in', 'A_ARG_TYPE_InstanceID')]


def _act(name, extra=None):
    return (name, list(_IN) + list(extra or []))


AV_ACTIONS = [
    _act('SetAVTransportURI', [('CurrentURI', 'in', 'AVTransportURI'),
                               ('CurrentURIMetaData', 'in', 'AVTransportURIMetaData')]),
    _act('SetNextAVTransportURI', [('NextURI', 'in', 'NextAVTransportURI'),
                                   ('NextURIMetaData', 'in', 'NextAVTransportURIMetaData')]),
    _act('GetMediaInfo', [('NrTracks', 'out', 'NumberOfTracks'),
                          ('MediaDuration', 'out', 'CurrentMediaDuration'),
                          ('CurrentURI', 'out', 'AVTransportURI'),
                          ('CurrentURIMetaData', 'out', 'AVTransportURIMetaData'),
                          ('NextURI', 'out', 'NextAVTransportURI'),
                          ('NextURIMetaData', 'out', 'NextAVTransportURIMetaData'),
                          ('PlayMedium', 'out', 'PlaybackStorageMedium'),
                          ('RecordMedium', 'out', 'RecordStorageMedium'),
                          ('WriteStatus', 'out', 'RecordMediumWriteStatus')]),
    _act('GetTransportInfo', [('CurrentTransportState', 'out', 'TransportState'),
                              ('CurrentTransportStatus', 'out', 'TransportStatus'),
                              ('CurrentSpeed', 'out', 'TransportPlaySpeed')]),
    _act('GetPositionInfo', [('Track', 'out', 'CurrentTrack'),
                             ('TrackDuration', 'out', 'CurrentTrackDuration'),
                             ('TrackMetaData', 'out', 'CurrentTrackMetaData'),
                             ('TrackURI', 'out', 'CurrentTrackURI'),
                             ('RelTime', 'out', 'RelativeTimePosition'),
                             ('AbsTime', 'out', 'AbsoluteTimePosition'),
                             ('RelCount', 'out', 'RelativeCounterPosition'),
                             ('AbsCount', 'out', 'AbsoluteCounterPosition')]),
    _act('GetDeviceCapabilities', [('PlayMedia', 'out', 'PossiblePlaybackStorageMedia'),
                                   ('RecMedia', 'out', 'PossibleRecordStorageMedia'),
                                   ('RecQualityModes', 'out', 'PossibleRecordQualityModes')]),
    _act('GetTransportSettings', [('PlayMode', 'out', 'CurrentPlayMode'),
                                  ('RecQualityMode', 'out', 'CurrentRecordQualityMode')]),
    (('Stop'), list(_IN)), (('Play'), list(_IN) + [('Speed', 'in', 'TransportPlaySpeed')]),
    (('Pause'), list(_IN)),
    (('Seek'), list(_IN) + [('Unit', 'in', 'A_ARG_TYPE_SeekMode'),
                            ('Target', 'in', 'A_ARG_TYPE_SeekTarget')]),
    (('Next'), list(_IN)), (('Previous'), list(_IN)),
    (('GetCurrentTransportActions'), list(_IN) + [('Actions', 'out', 'CurrentTransportActions')]),
]
AV_STATE = [
    ('TransportState', 'string', 'no'), ('TransportStatus', 'string', 'no'),
    ('PlaybackStorageMedium', 'string', 'no'), ('RecordStorageMedium', 'string', 'no'),
    ('PossiblePlaybackStorageMedia', 'string', 'no'), ('PossibleRecordStorageMedia', 'string', 'no'),
    ('CurrentPlayMode', 'string', 'no'), ('TransportPlaySpeed', 'string', 'no'),
    ('RecordMediumWriteStatus', 'string', 'no'), ('CurrentRecordQualityMode', 'string', 'no'),
    ('PossibleRecordQualityModes', 'string', 'no'), ('NumberOfTracks', 'ui4', 'no'),
    ('CurrentTrack', 'ui4', 'no'), ('CurrentTrackDuration', 'string', 'no'),
    ('CurrentMediaDuration', 'string', 'no'), ('CurrentTrackMetaData', 'string', 'no'),
    ('CurrentTrackURI', 'string', 'no'), ('AVTransportURI', 'string', 'no'),
    ('AVTransportURIMetaData', 'string', 'no'), ('NextAVTransportURI', 'string', 'no'),
    ('NextAVTransportURIMetaData', 'string', 'no'), ('RelativeTimePosition', 'string', 'no'),
    ('AbsoluteTimePosition', 'string', 'no'), ('RelativeCounterPosition', 'i4', 'no'),
    ('AbsoluteCounterPosition', 'i4', 'no'), ('CurrentTransportActions', 'string', 'no'),
    ('LastChange', 'string', 'yes'), ('A_ARG_TYPE_SeekMode', 'string', 'no'),
    ('A_ARG_TYPE_SeekTarget', 'string', 'no'), ('A_ARG_TYPE_InstanceID', 'ui4', 'no'),
]
RC_ACTIONS = [
    _act('ListPresets', [('CurrentPresetNameList', 'out', 'PresetNameList')]),
    _act('SelectPreset', [('PresetName', 'in', 'A_ARG_TYPE_PresetName')]),
    _act('GetVolume', [('Channel', 'in', 'A_ARG_TYPE_Channel'),
                       ('CurrentVolume', 'out', 'Volume')]),
    _act('SetVolume', [('Channel', 'in', 'A_ARG_TYPE_Channel'),
                       ('DesiredVolume', 'in', 'Volume')]),
    _act('GetMute', [('Channel', 'in', 'A_ARG_TYPE_Channel'), ('CurrentMute', 'out', 'Mute')]),
    _act('SetMute', [('Channel', 'in', 'A_ARG_TYPE_Channel'), ('DesiredMute', 'in', 'Mute')]),
    _act('GetVolumeDBRange', [('Channel', 'in', 'A_ARG_TYPE_Channel'),
                              ('MinValue', 'out', 'VolumeDB'), ('MaxValue', 'out', 'VolumeDB')]),
]
RC_STATE = [
    ('PresetNameList', 'string', 'no'), ('LastChange', 'string', 'yes'),
    ('Mute', 'boolean', 'no'), ('Volume', 'ui2', 'no'), ('VolumeDB', 'i2', 'no'),
    ('A_ARG_TYPE_Channel', 'string', 'no'), ('A_ARG_TYPE_InstanceID', 'ui4', 'no'),
    ('A_ARG_TYPE_PresetName', 'string', 'no'),
]
CM_ACTIONS = [
    (('GetProtocolInfo'), [('Source', 'out', 'SourceProtocolInfo'),
                           ('Sink', 'out', 'SinkProtocolInfo')]),
    (('GetCurrentConnectionIDs'), [('ConnectionIDs', 'out', 'CurrentConnectionIDs')]),
    _act('GetCurrentConnectionInfo', [('RcsID', 'out', 'A_ARG_TYPE_RcsID'),
                                     ('AVTransportID', 'out', 'A_ARG_TYPE_AVTransportID'),
                                     ('ProtocolInfo', 'out', 'A_ARG_TYPE_ProtocolInfo'),
                                     ('PeerConnectionManager', 'out', 'A_ARG_TYPE_ConnectionManager'),
                                     ('PeerConnectionID', 'out', 'A_ARG_TYPE_ConnectionID'),
                                     ('Direction', 'out', 'A_ARG_TYPE_Direction'),
                                     ('Status', 'out', 'A_ARG_TYPE_ConnectionStatus')]),
]
CM_STATE = [
    ('SourceProtocolInfo', 'string', 'yes'), ('SinkProtocolInfo', 'string', 'yes'),
    ('CurrentConnectionIDs', 'string', 'yes'), ('A_ARG_TYPE_ConnectionStatus', 'string', 'no'),
    ('A_ARG_TYPE_ConnectionManager', 'string', 'no'), ('A_ARG_TYPE_Direction', 'string', 'no'),
    ('A_ARG_TYPE_ProtocolInfo', 'string', 'no'), ('A_ARG_TYPE_ConnectionID', 'i4', 'no'),
    ('A_ARG_TYPE_AVTransportID', 'i4', 'no'), ('A_ARG_TYPE_RcsID', 'i4', 'no'),
]
SCPD_BY_SERVICE = {
    'AVTransport': _scpd(AV_ACTIONS, AV_STATE),
    'RenderingControl': _scpd(RC_ACTIONS, RC_STATE),
    'ConnectionManager': _scpd(CM_ACTIONS, CM_STATE),
}


def send_event(sid, short):
    """给订阅者推一条 NOTIFY（UPnP 事件）。

    ★★★ r655 补记（真实读数）：这个函数**以前根本不存在**，而 `do_SUBSCRIBE`
    与 `do_POST` 都在 `threading.Thread(target=send_event, ...)` 里引用它
    ⇒ 任何 `SetAVTransportURI`/`Play`/`Pause`/`Stop`/`Seek` 都会在"记账完成之后、
    回包之前"抛 `NameError`，连接被直接关掉。宿主 `curl` 看到的是
    `curl: (52) Empty reply from server`，手机侧看到的是"设备连不上" ——
    两个现象都在说同一件事：**这是仪器坏了，不是 App 推不进去**。
    补上实现之后才谈得上"渲染器真的收到了什么"。
    """
    item = SUBS.get(sid)
    if not item:
        return
    callback, service = item
    seq = SEQ.get(sid, 0)
    SEQ[sid] = seq + 1
    if service == 'AVTransport':
        props = (f'<Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">'
                 f'<InstanceID val="0"><TransportState val="{STATE["transport"]}"/>'
                 f'<CurrentTrackURI val="{STATE["uri"]}"/>'
                 f'<AVTransportURI val="{STATE["uri"]}"/></InstanceID></Event>')
    else:
        props = (f'<Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/">'
                 f'<InstanceID val="0"><Volume val="{STATE["volume"]}"/>'
                 f'<Mute val="{STATE["mute"]}"/></InstanceID></Event>')
    body = ('<?xml version="1.0"?><e:propertyset '
            'xmlns:e="urn:schemas-upnp-org:event-1-0">'
            f'<e:property><LastChange>{props}</LastChange></e:property></e:propertyset>')
    req = urllib.request.Request(
        callback,
        data=body.encode('utf-8'),
        method='NOTIFY',
        headers={
            'Content-Type': 'text/xml; charset="utf-8"',
            'NT': 'upnp:event',
            'NTS': 'upnp:propchange',
            'SID': sid,
            'SEQ': str(seq),
        },
    )
    try:
        urllib.request.urlopen(req, timeout=2).read()
        log('EVENT', f'NOTIFY {service} seq={seq} → {callback}')
    except Exception as exc:  # 订阅方不收也算正常（很多设备订阅完就断了）
        log('EVENT', f'NOTIFY 失败 {service} seq={seq} → {callback}: {exc}')


def env(name, inner, body):
    """拼 SOAP 响应信封。

    ★ r655 补记：这里原本签名是 `env(name, inner)`、却引用了未定义的 `body`，
    而唯一调用点是 `env(action, inner, bodies[action])` ⇒ **每个 SOAP 动作都**
    抛 `TypeError`（先是 `NameError: send_event`，再是这个），客户端只看到
    `Empty reply from server`。仪器先修好，才谈得上"App 推了什么"。
    """
    return f'''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:{name}Response xmlns:u="{inner}">{body}</u:{name}Response></s:Body></s:Envelope>'''


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype='text/xml; charset="utf-8"'):
        raw = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Server', 'SynHub-r445/1.0 UPnP/1.0')
        self.send_header('EXT', '')
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        log('HTTP', f'GET {self.path} from {self.client_address[0]}')
        if self.path in ('/rootDesc.xml', '/'):
            return self._send(200, root_desc())
        m = re.fullmatch(r'/([A-Za-z]+)\.xml', self.path)
        if m:
            svc = m.group(1)
            if svc in SCPD_BY_SERVICE:
                return self._send(200, SCPD_BY_SERVICE[svc])
            return self._send(404, '<html><body>no such SCPD</body></html>', 'text/html')
        return self._send(404, '<html><body>404</body></html>')

    def do_HEAD(self):
        log('HTTP', f'HEAD {self.path} from {self.client_address[0]}')
        self._send(200, '')

    def do_SUBSCRIBE(self):
        cb = self.headers.get('CALLBACK', '')
        m = re.search(r'<([^>]+)>', cb)
        callback = m.group(1) if m else ''
        short = self.path.split('/')[1] or 'AVTransport'
        sid = 'uuid:r445-sub-' + uuid.uuid4().hex[:8]
        log('HTTP', f'SUBSCRIBE {self.path} from {self.client_address[0]} CALLBACK={callback}')
        self.send_response(200)
        self.send_header('SID', sid)
        self.send_header('TIMEOUT', 'Second-1800')
        self.send_header('Content-Length', '0')
        self.end_headers()
        if callback:
            SUBS[sid] = (callback, short)
            SEQ[sid] = 0
            # ★ UPnP 事件ing 规矩：SUBSCRIBE 成功之后必须**立刻**推一条 SEQ:0 的初始事件
            threading.Thread(
                target=send_event, args=(sid, short), daemon=True
            ).start()

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace')
        soap = self.headers.get('SOAPAction', '').strip('"')
        action = soap.split('#')[-1] if soap else '(no SOAPAction)'
        inner = soap.split('#')[0] if soap else DEVICE_TYPE
        args = dict(re.findall(r'<([A-Za-z]+)>([^<]*)</\1>', body))
        extra = ''
        if action == 'SetAVTransportURI':
            STATE['uri'] = args.get('CurrentURI', '')
            STATE['metadata'] = args.get('CurrentURIMetaData', '')
            extra = json.dumps({'CurrentURI': STATE['uri'], 'meta_len': len(STATE['metadata'])}, ensure_ascii=False)
        elif action == 'Play':
            STATE['transport'] = 'PLAYING'
        elif action == 'Pause':
            STATE['transport'] = 'PAUSED_PLAYBACK'
        elif action == 'Stop':
            STATE['transport'] = 'STOPPED'
            STATE['uri'] = ''
        elif action == 'SetVolume':
            try:
                STATE['volume'] = int(args.get('DesiredVolume', STATE['volume']))
            except ValueError:
                pass
        elif action == 'SetMute':
            STATE['mute'] = 1 if args.get('DesiredMute') in ('1', 'true') else 0
        # 记账：动作名 + 参数 + 请求体（NAS 到底发了什么，逐条留证据）
        log('SOAP', f'{action} from {self.client_address[0]} args={json.dumps(args, ensure_ascii=False)} {extra}')
        if action in ('SetAVTransportURI', 'Play', 'Pause', 'Stop', 'Next', 'Previous', 'Seek'):
            for sid, (_cb, svc) in list(SUBS.items()):
                if svc == 'AVTransport':
                    threading.Thread(target=send_event, args=(sid, 'AVTransport'), daemon=True).start()
        with LOG_LOCK, open(os.path.join(os.path.dirname(LOG_PATH or "/tmp/x"), 'r445_soap_bodies.log'), 'a', encoding='utf-8') as f:
            f.write(f'===== {time.strftime("%H:%M:%S")} {action} {self.path}\n{body}\n')

        bodies = {
            'SetAVTransportURI': '',
            'SetNextAVTransportURI': '',
            'Play': '<Speed>1</Speed>',
            'Pause': '',
            'Stop': '',
            'Next': '',
            'Previous': '',
            'Seek': '',
            'GetMediaInfo': (f'<NrTracks>1</NrTracks><MediaDuration>00:00:00</MediaDuration>'
                             f'<CurrentURI>{STATE["uri"]}</CurrentURI>'
                             f'<CurrentURIMetaData></CurrentURIMetaData><NextURI></NextURI>'
                             f'<NextURIMetaData></NextURIMetaData><PlayMedium>NETWORK</PlayMedium>'
                             f'<RecordMedium>NOT_IMPLEMENTED</RecordMedium><WriteStatus>NOT_IMPLEMENTED</WriteStatus>'),
            'GetTransportInfo': (f'<CurrentTransportState>{STATE["transport"]}</CurrentTransportState>'
                                 f'<CurrentTransportStatus>OK</CurrentTransportStatus>'
                                 f'<CurrentSpeed>1</CurrentSpeed>'),
            'GetPositionInfo': (f'<Track>1</Track><TrackDuration>00:03:30</TrackDuration>'
                                f'<TrackMetaData></TrackMetaData><TrackURI>{STATE["uri"]}</TrackURI>'
                                f'<RelTime>00:00:10</RelTime><AbsTime>00:00:10</AbsTime>'
                                f'<RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>'),
            'GetDeviceCapabilities': ('<PlayMedia>NETWORK</PlayMedia><RecMedia>NOT_IMPLEMENTED</RecMedia>'
                                      '<RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>'),
            'GetTransportSettings': '<PlayMode>NORMAL</PlayMode><RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>',
            'GetCurrentTransportActions': '<Actions>Play,Stop,Pause,Seek,Next,Previous</Actions>',
            'GetProtocolInfo': ('<Source></Source><Sink>' + (DLNA_SINK if VARIANT in ('dlna', 'v2canon')
                                else 'http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,'
                                     'http-get:*:audio/x-flac:*,http-get:*:audio/*:*,http-get:*:*:*') + '</Sink>'),
            'GetCurrentConnectionIDs': '<ConnectionIDs>0</ConnectionIDs>',
            'GetCurrentConnectionInfo': ('<RcsID>0</RcsID><AVTransportID>0</AVTransportID>'
                                         '<ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager>'
                                         '<PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction>'
                                         '<Status>OK</Status>'),
            'ListPresets': '<CurrentPresetNameList>FactoryDefaults</CurrentPresetNameList>',
            'SelectPreset': '',
            'GetVolume': f'<CurrentVolume>{STATE["volume"]}</CurrentVolume>',
            'GetMute': f'<CurrentMute>{STATE["mute"]}</CurrentMute>',
            'GetVolumeDBRange': '<MinValue>-102400</MinValue><MaxValue>0</MaxValue>',
        }
        if action not in bodies:
            log('SOAP', f'!! 未实现的动作 {action} —— 回 500（如实，不假装成功）')
            return self._send(500, '<html><body>unsupported action</body></html>', 'text/html')
        return self._send(200, env(action, inner, bodies[action]))


class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def ssdp_loop(stop):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', SSDP_PORT))
    mreq = struct.pack('4s4s', socket.inet_aton(SSDP_ADDR), socket.inet_aton(Cfg.ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)

    all_targets = [('upnp:rootdevice', f'{Cfg.udn}::upnp:rootdevice'), (Cfg.udn, Cfg.udn)] + [
        (st, f'{Cfg.udn}::{st}') for st in SERVICE_TYPES
    ] + [(DEVICE_TYPE, f'{Cfg.udn}::{DEVICE_TYPE}')]

    def notify(nt, usn, alive=True):
        method = 'NOTIFY * HTTP/1.1'
        msg = '\r\n'.join([
            method,
            f'HOST: {SSDP_ADDR}:{SSDP_PORT}',
            'CACHE-CONTROL: max-age=1800',
            f'LOCATION: http://{Cfg.ip}:{Cfg.port}/rootDesc.xml',
            'SERVER: SynHub-r445/1.0 UPnP/1.0',
            f'NT: {nt}',
            f'NTS: {"ssdp:alive" if alive else "ssdp:byebye"}',
            f'USN: {usn}',
            '', '']).encode()
        for _ in range(2):
            sock.sendto(msg, (SSDP_ADDR, SSDP_PORT))

    def msearch_reply(addr, st, mx):
        targets = all_targets if st == 'ssdp:all' else [t for t in all_targets if t[0] == st]
        if not targets:
            # ★ 仪器145：**只应答自己真的实现了的身份**。
            # 之前对任意 `urn:...:service:*` 都拿本 UDN 应答 ⇒ 连 `ContentDirectory:1`（媒体服务器）
            # 我们也"承认"了，于是 NAS 把本渲染器**同时**登记进了 `MediaServer.list`
            # （读到 `{id:'',path:'',title:'r445 SynHub Renderer',type:'folder'}`）—— 这是**假身份**，
            # 会让"渲染器没被登记"这个结论变得不可信。不认识就**静默忽略**并记账。
            if st.startswith('urn:') or st.startswith('uuid:'):
                log('SSDP', f'M-SEARCH ST={st} 来自 {addr[0]} ⇒ **忽略**（本设备没有这个服务/身份）')
            return
        for nt, usn in targets:
            msg = '\r\n'.join([
                'HTTP/1.1 200 OK',
                f'CACHE-CONTROL: max-age=1800',
                f'DATE: {time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime())}',
                'EXT:',
                f'LOCATION: http://{Cfg.ip}:{Cfg.port}/rootDesc.xml',
                'SERVER: SynHub-r445/1.0 UPnP/1.0',
                f'ST: {nt}',
                f'USN: {usn}',
                '', '']).encode()
            sock.sendto(msg, addr)
            log('SSDP', f'M-SEARCH {st} from {addr[0]} ⇒ 应答 ST={nt}')

    log('SSDP', f'监听 {SSDP_ADDR}:{SSDP_PORT}（本机 {Cfg.ip}）')
    for nt, usn in all_targets:
        notify(nt, usn, True)
    last_notify = time.time()
    try:
        while not stop.is_set():
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                if time.time() - last_notify > 300:
                    for nt, usn in all_targets:
                        notify(nt, usn, True)
                    last_notify = time.time()
                continue
            text = data.decode('utf-8', 'replace')
            first = text.split('\r\n')[0]
            if first.startswith('M-SEARCH'):
                st = (re.search(r'(?im)^ST:\s*(.+)$', text) or [None, ''])[1].strip()
                mx = (re.search(r'(?im)^MX:\s*(.+)$', text) or [None, ''])[1].strip()
                log('SSDP', f'收到 M-SEARCH ST={st} MX={mx} 来自 {addr[0]}')
                msearch_reply(addr, st, mx)
            elif first.startswith('NOTIFY'):
                nt = (re.search(r'(?im)^NT:\s*(.+)$', text) or [None, ''])[1].strip()
                if nt and 'MediaRenderer' in nt:
                    log('SSDP', f'另外的渲染器通告 NT={nt} 来自 {addr[0]}')
    finally:
        for nt, usn in all_targets:
            notify(nt, usn, False)
        sock.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=49494)
    ap.add_argument('--name', default='r445 Test Renderer')
    ap.add_argument('--log', default='/tmp/r445/renderer.log')
    ap.add_argument('--variant', default='basic',
                    choices=['basic', 'canonical', 'v2', 'v2canon', 'urlbase', 'dlna'])
    a = ap.parse_args()
    global LOG_PATH, VARIANT
    VARIANT = a.variant
    LOG_PATH = a.log
    Cfg.port = a.port
    Cfg.name = a.name
    Cfg.ip = local_ip()
    os.makedirs(os.path.dirname(a.log) or '.', exist_ok=True)
    open(a.log, 'w', encoding='utf-8').close()
    log('BOOT', f'UDN={Cfg.udn} IP={Cfg.ip} PORT={Cfg.port} NAME={Cfg.name!r} VARIANT={VARIANT}')
    srv = Threaded(('0.0.0.0', Cfg.port), Handler)
    stop = threading.Event()
    t = threading.Thread(target=ssdp_loop, args=(stop,), daemon=True)
    t.start()
    log('BOOT', f'设备描述 http://{Cfg.ip}:{Cfg.port}/rootDesc.xml')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log('QUIT', '收到 Ctrl-C')
    finally:
        stop.set()
        time.sleep(1.0)
        srv.server_close()


if __name__ == '__main__':
    main()
