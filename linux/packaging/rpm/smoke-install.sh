#!/bin/bash
# Chạy TRONG container Fedora / EL sạch (root): dnf install mọi .rpm trong /rpms, rồi kiểm
# file nằm đúng chỗ Fcitx5/IBus tìm, rpm -V, engine IBus (+ IM Fcitx5 nếu có), công cụ văn
# bản, app cài đặt import được. In "SMOKE OK" khi đạt.
set -u
. /etc/os-release
fail=0
bad() { echo "FAIL: $*"; fail=1; }
extra="ibus dbus-daemon python3-gobject"
ls /rpms/viettelex-fcitx5-*.rpm >/dev/null 2>&1 && extra="$extra fcitx5"
dnf -y -q install /rpms/*.rpm $extra >/tmp/dnf.log 2>&1 \
  || { tail -20 /tmp/dnf.log; echo "SMOKE FAIL: dnf"; exit 1; }
echo "$PRETTY_NAME: $(rpm -qa 'viettelex*' 'libviettelex*' | sort | tr '\n' ' ')"

for p in $(rpm -qa 'viettelex*' 'libviettelex*'); do
  out=$(rpm -V "$p") || bad "rpm -V $p: $out"
done
L=$(rpm -E %_libdir)
test -f "$L/viettelex/libtelexcore.so" || bad "libtelexcore"
test -x "$L/viettelex/viettelex-text-tool" || bad "text tool"
grep -q "<exec>/usr/libexec/ibus-engine-viettelex --ibus</exec>" /usr/share/ibus/component/viettelex.xml || bad "ibus component"
test -x /usr/libexec/ibus-engine-viettelex || bad "ibus engine"
test ! -e /usr/libexec/viettelex/viettelex-update || bad "apt updater helper shipped"
grep -qx rpm /usr/share/viettelex-settings/install-method || bad "install-method"
if rpm -q viettelex-fcitx5 >/dev/null; then
  test -f "$L/fcitx5/viettelex.so" || bad "fcitx5 addon .so"
  test -f /usr/share/fcitx5/addon/viettelex.conf || bad "fcitx5 addon conf"
  test -f /usr/share/fcitx5/inputmethod/viettelex.conf || bad "fcitx5 im conf"
fi
ldd "$L/viettelex/viettelex-text-tool" /usr/libexec/ibus-engine-viettelex $(ls "$L"/fcitx5/viettelex.so 2>/dev/null) \
  | grep "not found" && bad "missing libraries"
python3 -c "import sys; sys.path.insert(0, '/usr/share/viettelex-settings'); \
import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1'); \
from gi.repository import Gtk, Adw; import viettelex_settings.app, viettelex_settings.updater as u; \
print('settings', viettelex_settings.VERSION, 'Adw', Adw.MAJOR_VERSION, Adw.MINOR_VERSION, 'install', u.install_method())" \
  || bad "settings import"

export HOME=/tmp/h; mkdir -p "$HOME"
dbus-run-session -- bash -c '
  fail=0
  out=$(printf "toi di hoc" | '"$L"'/viettelex/viettelex-text-tool addTones 2>&1)
  if [ "$out" = "tôi đi học" ]; then echo "text-tool: OK"; else echo "text-tool: FAIL ($out)"; fail=1; fi
  if command -v fcitx5 >/dev/null && rpm -q viettelex-fcitx5 >/dev/null; then
    fcitx5 --disable=wayland,xim,x11 >/tmp/f.log 2>&1 & sleep 5
    python3 - <<PY || fail=1
import sys
from gi.repository import Gio
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
p = Gio.DBusProxy.new_sync(bus, 0, None, "org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1", None)
ims = [i[0] for i in p.call_sync("AvailableInputMethods", None, 0, 3000, None).unpack()[0]]
print("fcitx5:", "viettelex" in ims and "viettelex OK" or "viettelex MISSING")
sys.exit(0 if "viettelex" in ims else 1)
PY
  fi
  ibus-daemon -x -r --panel=disable >/tmp/i.log 2>&1 & sleep 5
  if ibus list-engine 2>/dev/null | grep -q "viettelex -"; then echo "ibus: viettelex OK"; else echo "ibus: viettelex MISSING"; fail=1; fi
  exit $fail' || fail=1
dnf -y -q remove 'viettelex*' 'libviettelex*' >/dev/null 2>&1 || bad "dnf remove"
test ! -e "$L/viettelex/libtelexcore.so" || bad "leftover after remove"
[ $fail = 0 ] && echo "SMOKE OK" || echo "SMOKE FAIL"
