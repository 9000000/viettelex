// watcher.cpp — see watcher.h.
#include "viettelex/watcher.h"

#include <cstring>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

namespace viettelex {

SettingsWatcher::Stamp SettingsWatcher::stampOf(const std::string &path) {
    Stamp s;
    struct stat st;
    if (::stat(path.c_str(), &st) != 0) return s;
    s.mtime = st.st_mtim;
    s.size = st.st_size;
    s.ino = st.st_ino;
    return s;
}

SettingsWatcher::SettingsWatcher(std::string dir) : dir_(std::move(dir)) {
    mkdirs(dir_);
    fd_ = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    addWatch();
    if (wd_ < 0 && fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    reload();
}

SettingsWatcher::~SettingsWatcher() {
    if (fd_ >= 0) ::close(fd_);
}

void SettingsWatcher::addWatch() {
    if (fd_ < 0) return;
    wd_ = inotify_add_watch(fd_, dir_.c_str(), IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE | IN_CREATE | IN_MOVED_FROM);
}

bool SettingsWatcher::drain() {
    if (fd_ < 0) return false;
    bool relevant = false;
    alignas(struct inotify_event) char buf[4096];
    for (;;) {
        ssize_t n = ::read(fd_, buf, sizeof buf);
        if (n <= 0) break;
        for (char *p = buf; p < buf + n;) {
            auto *ev = reinterpret_cast<struct inotify_event *>(p);
            // The directory itself went away (removed / renamed over): the watch is gone, so
            // focus-in falls back to the mtime check (changedOnDiskUnwatched) from now on.
            if ((ev->mask & IN_IGNORED) && ev->wd == wd_) {
                wd_ = -1;
                relevant = true;
            }
            if (ev->len > 0) {
                const char *name = ev->name;
                // IN_CREATE of config.toml.tmp is noise; the rename (IN_MOVED_TO) is the signal.
                if ((std::strcmp(name, "config.toml") == 0 || std::strcmp(name, "shortcuts.yml") == 0) &&
                    !(ev->mask & IN_CREATE))
                    relevant = true;
            }
            p += sizeof(struct inotify_event) + ev->len;
        }
    }
    return relevant;
}

bool SettingsWatcher::changedOnDisk() {
    return !(stampOf(dir_ + "/config.toml") == cfgStamp_) || !(stampOf(dir_ + "/shortcuts.yml") == scStamp_);
}

bool SettingsWatcher::changedOnDiskUnwatched() {
    if (watching()) return false;
    if (fd_ >= 0) addWatch();  // the directory may be back
    return changedOnDisk();
}

const Settings &SettingsWatcher::reload() {
    cfgStamp_ = stampOf(dir_ + "/config.toml");
    Stamp sc = stampOf(dir_ + "/shortcuts.yml");
    std::string text;
    Settings s = readFile(dir_ + "/config.toml", text) ? parseConfig(text) : Settings();
    if (loaded_ && sc == scStamp_) {
        s.shortcuts = settings_.shortcuts;  // config.toml changed alone: same table
    } else {
        std::string yml;
        if (readFile(dir_ + "/shortcuts.yml", yml)) {
            s.shortcuts = std::make_shared<ShortcutTable>(parseShortcuts(yml));
            ++shortcutParses_;
        }
    }
    scStamp_ = sc;
    settings_ = std::move(s);
    loaded_ = true;
    ++generation_;
    return settings_;
}

}  // namespace viettelex
