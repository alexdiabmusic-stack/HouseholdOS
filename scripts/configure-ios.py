#!/usr/bin/env python3
"""Write public iOS configuration. Never accepts provider/server secrets."""
import argparse
import base64
import json
import plistlib
import re
from pathlib import Path
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument('--url', required=True, help='Supabase HTTPS project URL')
parser.add_argument('--publishable-key', required=True, help='Public anon/publishable key only')
parser.add_argument('--bundle-id', required=True, help='Existing registered App Store bundle identifier')
parser.add_argument('--app-link-domain', help='Owned domain configured for Plaid Universal Links')
args = parser.parse_args()
endpoint = urlparse(args.url)
if endpoint.scheme != 'https' or not endpoint.hostname or endpoint.path not in ('', '/') or endpoint.query or endpoint.fragment or endpoint.username or any(c in args.url for c in '\r\n$'):
    parser.error('Use an HTTPS Supabase URL')
key = args.publishable_key
if not re.fullmatch(r'sb_publishable_[A-Za-z0-9_-]+', key):
    try:
        part = key.split('.')[1]
        payload = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
        if payload.get('role') != 'anon':
            raise ValueError()
    except (ValueError, IndexError, json.JSONDecodeError):
        parser.error('Only a public anon or sb_publishable key may enter the iOS build')
if any(c in args.bundle_id for c in '\r\n$; /') or args.bundle_id.count('.') < 2:
    parser.error('Use the registered reverse-domain bundle identifier')
root = Path(__file__).resolve().parent.parent
values = [f'SUPABASE_URL = {args.url.replace("https://", "https:/$()/")}', f'SUPABASE_PUBLISHABLE_KEY = {key}', f'PRODUCT_BUNDLE_IDENTIFIER = {args.bundle_id}']
if args.app_link_domain:
    domain = args.app_link_domain
    if any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in domain) or '.' not in domain:
        parser.error('Use a hostname without a scheme or path')
    with (root/'Config/Local.entitlements').open('wb') as f:
        plistlib.dump({'com.apple.developer.associated-domains': [f'applinks:{domain}']}, f)
    values.append('CODE_SIGN_ENTITLEMENTS = Config/Local.entitlements')
(root/'Config/Local.xcconfig').write_text('\n'.join(values) + '\n')
print('Public iOS configuration written to gitignored Config/Local.xcconfig.')
