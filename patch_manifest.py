#!/usr/bin/env python3
"""Patches the Flutter-generated AndroidManifest.xml for the bridge app:
permissions, USB host feature, cleartext localhost, and the USB-attach
intent filter (which uses res/xml/device_filter.xml)."""
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    xml = f.read()

if "USB_DEVICE_ATTACHED" in xml:
    print("manifest already patched")
    sys.exit(0)

PERMS = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-feature android:name="android.hardware.usb.host" android:required="false"/>
    <uses-feature android:name="android.hardware.camera" android:required="false"/>
"""

# 1. permissions/features just before <application
if "<application" not in xml:
    sys.exit("no <application> tag found")
xml = xml.replace("<application", PERMS + "    <application", 1)

# 2. allow cleartext (http://localhost) on the application tag
xml = re.sub(r"<application", '<application android:usesCleartextTraffic="true"', xml, count=1)

# 3. USB attach intent filter + device filter inside the main activity
USB = """            <intent-filter>
                <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
            </intent-filter>
            <meta-data android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
                       android:resource="@xml/device_filter"/>
        </activity>"""
if "</activity>" not in xml:
    sys.exit("no </activity> tag found")
xml = xml.replace("</activity>", USB, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
print("manifest patched")
