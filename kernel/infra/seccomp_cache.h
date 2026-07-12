#ifndef __KSU_H_KERNEL_COMPAT
#define __KSU_H_KERNEL_COMPAT

#include <linux/fs.h>
#include <linux/version.h>

/* Forward declaration: the full layout lives in kernel/seccomp.c and is only
 * redeclared by seccomp_cache.c on kernels that have the seccomp action cache
 * (>= 5.9). The opaque pointer is enough for callers passing
 * current->seccomp.filter around. */
struct seccomp_filter;

extern void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr);
extern void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr);

#endif
