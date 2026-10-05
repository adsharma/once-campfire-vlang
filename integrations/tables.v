// Address policy from the pinned Surfguard tables in
// reference/crates/campfire/src/integrations/net/guard.rs.
module integrations

const blocked_v4 = ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '168.63.129.16/32',
	'169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24',
	'192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4',
	'240.0.0.0/4']

const blocked_v6 = ['::/128', '100::/64', '100:0:0:1::/64', '2001::/32', '2001:2::/48',
	'2001:db8::/32', '2002::/16', '3fff::/20', '5f00::/16', 'fec0::/10', 'ff00::/8']

const allocated_v6 = ['2001::/23', '2001:200::/23', '2001:400::/23', '2001:600::/23', '2001:800::/22',
	'2001:c00::/23', '2001:e00::/23', '2001:1200::/23', '2001:1400::/22', '2001:1800::/23',
	'2001:1a00::/23', '2001:1c00::/22', '2001:2000::/19', '2001:4000::/23', '2001:4200::/23',
	'2001:4400::/23', '2001:4600::/23', '2001:4800::/23', '2001:4a00::/23', '2001:4c00::/23',
	'2001:5000::/20', '2001:8000::/19', '2001:a000::/20', '2001:b000::/20', '2002::/16', '2003::/18',
	'2400::/12', '2410::/12', '2600::/12', '2610::/23', '2620::/23', '2630::/12', '2800::/12',
	'2a00::/12', '2a10::/12', '2c00::/12']

const ietf_public = ['2001:3::/32', '2001:4:112::/48']

const mapped_ranges = ['::ffff:0:0/96', '::/96', '64:ff9b:1::/48']
const translated_ranges = ['64:ff9b::/96', '::ffff:0:0:0/96']
const private_v6 = ['fc00::/7', 'fe80::/10', '2001::/23']

const push_hosts = ['jmt17.google.com', 'fcm.googleapis.com', 'updates.push.services.mozilla.com',
	'web.push.apple.com', 'notify.windows.com']

const webhook_types = {
	'text/html':                         ['html', 'text/html']
	'application/xhtml+xml':             ['html', 'text/html']
	'text/plain':                        ['text', 'text/plain']
	'text/javascript':                   ['js', 'text/javascript']
	'application/javascript':            ['js', 'text/javascript']
	'application/x-javascript':          ['js', 'text/javascript']
	'text/css':                          ['css', 'text/css']
	'text/calendar':                     ['ics', 'text/calendar']
	'text/csv':                          ['csv', 'text/csv']
	'text/vcard':                        ['vcf', 'text/vcard']
	'text/vtt':                          ['vtt', 'text/vtt']
	'vtt':                               ['vtt', 'text/vtt']
	'text/markdown':                     ['md', 'text/markdown']
	'image/png':                         ['png', 'image/png']
	'image/jpeg':                        ['jpeg', 'image/jpeg']
	'image/gif':                         ['gif', 'image/gif']
	'image/bmp':                         ['bmp', 'image/bmp']
	'image/tiff':                        ['tiff', 'image/tiff']
	'image/svg+xml':                     ['svg', 'image/svg+xml']
	'image/webp':                        ['webp', 'image/webp']
	'video/mpeg':                        ['mpeg', 'video/mpeg']
	'audio/mpeg':                        ['mp3', 'audio/mpeg']
	'audio/ogg':                         ['ogg', 'audio/ogg']
	'audio/aac':                         ['m4a', 'audio/aac']
	'audio/mp4':                         ['m4a', 'audio/aac']
	'video/webm':                        ['webm', 'video/webm']
	'video/mp4':                         ['mp4', 'video/mp4']
	'font/otf':                          ['otf', 'font/otf']
	'font/ttf':                          ['ttf', 'font/ttf']
	'font/woff':                         ['woff', 'font/woff']
	'font/woff2':                        ['woff2', 'font/woff2']
	'application/xml':                   ['xml', 'application/xml']
	'text/xml':                          ['xml', 'application/xml']
	'application/x-xml':                 ['xml', 'application/xml']
	'application/rss+xml':               ['rss', 'application/rss+xml']
	'application/atom+xml':              ['atom', 'application/atom+xml']
	'application/x-yaml':                ['yaml', 'application/x-yaml']
	'text/yaml':                         ['yaml', 'application/x-yaml']
	'multipart/form-data':               ['multipart_form', 'multipart/form-data']
	'application/x-www-form-urlencoded': ['url_encoded_form', 'application/x-www-form-urlencoded']
	'application/json':                  ['json', 'application/json']
	'text/x-json':                       ['json', 'application/json']
	'application/jsonrequest':           ['json', 'application/json']
	'application/problem+json':          ['json', 'application/json']
	'application/pdf':                   ['pdf', 'application/pdf']
	'application/zip':                   ['zip', 'application/zip']
	'application/gzip':                  ['gzip', 'application/gzip']
	'application/x-gzip':                ['gzip', 'application/x-gzip']
	'text/vnd.turbo-stream.html':        ['turbo_stream', 'text/vnd.turbo-stream.html']
}
