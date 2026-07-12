#include "feature/selinux_hide.h"
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/printk.h>

#include "policy/allowlist.h"
#include "klog.h" // IWYU pragma: keep
#include "runtime/ksud_boot.h"
#include "runtime/ksud.h"
#include "manager/manager_observer.h"
#include "manager/throne_tracker.h"
#include "infra/symbol_resolver.h"

bool ksu_module_mounted __read_mostly = false;
bool ksu_boot_completed __read_mostly = false;

void on_post_fs_data(void)
{
    static bool done = false;

    if (done) {
        pr_info("on_post_fs_data already done\n");
        return;
    }

    done = true;
    pr_info("on_post_fs_data!\n");

    ksu_load_allow_list();
    ksu_observer_init();
    // Sanity check for safe mode only needs early-boot input samples.
    ksu_stop_input_hook_runtime();
    ksu_selinux_hide_handle_post_fs_data();
}

// ext4_unregister_sysfs() is an ext4 internal helper that is not always
// exported to modules (it is absent on some pre-5.x kernels, e.g. 4.19).
// Resolve it at runtime via kallsyms so the module links regardless of whether
// the symbol is exported, and simply skip the unregister when it is missing.
typedef void (*ext4_unregister_sysfs_fn)(struct super_block *sb);

int nuke_ext4_sysfs(const char *mnt)
{
    struct path path;
    ext4_unregister_sysfs_fn unregister_sysfs;
    int err = kern_path(mnt, 0, &path);

    if (err) {
        pr_err("nuke path err: %d\n", err);
        return err;
    }

    if (strcmp(path.dentry->d_inode->i_sb->s_type->name, "ext4") != 0) {
        pr_info("nuke but module aren't mounted\n");
        path_put(&path);
        return -EINVAL;
    }

    unregister_sysfs = (ext4_unregister_sysfs_fn)find_kernel_symbol_exact("ext4_unregister_sysfs");
    if (!unregister_sysfs) {
        pr_warn("nuke_ext4_sysfs: ext4_unregister_sysfs not found, skip\n");
        path_put(&path);
        return -ENOSYS;
    }

    unregister_sysfs(path.dentry->d_inode->i_sb);
    path_put(&path);
    return 0;
}

void on_module_mounted(void)
{
    pr_info("on_module_mounted!\n");
    ksu_module_mounted = true;
}

void on_boot_completed(void)
{
    ksu_boot_completed = true;
    pr_info("on_boot_completed!\n");
    track_throne(true);
    ksu_selinux_hide_drop_backup_if_unused();
}
