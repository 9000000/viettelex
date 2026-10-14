// watcher.h — live settings: inotify on the config dir + mtime fallback.
// The frontend polls `fd()` in its own event loop and calls `drain()` when readable.
#pragma once

#include "viettelex/settings.h"

#include <cstdint>
#include <ctime>
#include <string>
#include <sys/types.h>

namespace viettelex {

class SettingsWatcher {
public:
    explicit SettingsWatcher(std::string dir = configDir());
    ~SettingsWatcher();
    SettingsWatcher(const SettingsWatcher &) = delete;
    SettingsWatcher &operator=(const SettingsWatcher &) = delete;

    int fd() const { return fd_; }        // -1 when inotify is unavailable
    // Reads pending inotify events; true if config.toml/shortcuts.yml changed.
    bool drain();
    // mtime check; true if either file changed since last load.
    bool changedOnDisk();
    // Focus-in fallback: changedOnDisk() only when inotify does not watch the directory
    // (unavailable, or the directory was removed / replaced — the watch is then gone).
    // While the watch is live, drain() already reports every change: no stat per focus.
    bool changedOnDiskUnwatched();
    bool watching() const { return fd_ >= 0 && wd_ >= 0; }
    // Reloads from disk and records mtimes. shortcuts.yml is parsed again only when the file
    // itself changed (mtime / size / inode); otherwise the previous table is kept.
    const Settings &reload();
    const Settings &settings() const { return settings_; }
    const std::string &dir() const { return dir_; }
    // Bumped by every reload(): frontends key caches derived from the settings on it.
    uint64_t generation() const { return generation_; }
    // Tests: how many times shortcuts.yml was parsed.
    int shortcutParses() const { return shortcutParses_; }

private:
    struct Stamp {
        struct timespec mtime = {0, 0};
        off_t size = -1;
        ino_t ino = 0;
        bool operator==(const Stamp &o) const {
            return mtime.tv_sec == o.mtime.tv_sec && mtime.tv_nsec == o.mtime.tv_nsec && size == o.size &&
                   ino == o.ino;
        }
    };
    static Stamp stampOf(const std::string &path);
    void addWatch();
    std::string dir_;
    int fd_ = -1;
    int wd_ = -1;
    Settings settings_;
    Stamp cfgStamp_, scStamp_;
    bool loaded_ = false;
    uint64_t generation_ = 0;
    int shortcutParses_ = 0;
};

}  // namespace viettelex
