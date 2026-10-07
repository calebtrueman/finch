/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_containermanager's "seams": tables of the system functions the
 * library calls (file system, passwd, notify, dispatch, quarantine, sandbox)
 * that tests can replace, and the pointers to the tables in use. Same
 * functions, same order and same sizes as macOS 26.4's tables (generated from
 * them); one FS slot is empty there too.
 *
 * Declared without their headers: only the addresses are taken.
 */

extern void __getattrlist(void);
extern void __lchown(void);
extern void __lseek(void);
extern void __setattrlist(void);
extern void _qtn_error(void);
extern void _qtn_file_alloc(void);
extern void _qtn_file_apply_to_path(void);
extern void _qtn_file_free(void);
extern void _qtn_file_get_flags(void);
extern void _qtn_file_init(void);
extern void _qtn_file_init_with_path(void);
extern void _qtn_file_set_flags(void);
extern void _qtn_file_set_identifier(void);
extern void _qtn_file_set_metadata(void);
extern void _qtn_file_set_timestamp(void);
extern void acl_add_flag_np(void);
extern void acl_add_perm(void);
extern void acl_create_entry(void);
extern void acl_delete_perm(void);
extern void acl_free(void);
extern void acl_get_entry(void);
extern void acl_get_file(void);
extern void acl_get_flagset_np(void);
extern void acl_get_permset(void);
extern void acl_get_tag_type(void);
extern void acl_init(void);
extern void acl_set_file(void);
extern void acl_set_flagset_np(void);
extern void acl_set_permset(void);
extern void acl_set_qualifier(void);
extern void acl_set_tag_type(void);
extern void acl_to_text(void);
extern void chmod(void);
extern void chown(void);
extern void close(void);
extern void closedir(void);
extern void container_class_supports_data_subdirectory(void);
extern void container_paths_copy_container_at(void);
extern void container_pwd_get_cached_current_user_home_path(void);
extern void container_realpath(void);
extern void copyfile(void);
extern void dirfd(void);
extern void dirstat_np(void);
extern void dispatch_assert_queue_not(void);
extern void dispatch_barrier_sync(void);
extern void dispatch_queue_attr_make_with_autorelease_frequency(void);
extern void dispatch_queue_create(void);
extern void dispatch_release(void);
extern void dispatch_retain(void);
extern void dup(void);
extern void fchflags(void);
extern void fchmod(void);
extern void fchmodx_np(void);
extern void fchown(void);
extern void fcntl(void);
extern void fdopendir(void);
extern void fflagstostr(void);
extern void fgetattrlist(void);
extern void fgetxattr(void);
extern void filesec_free(void);
extern void filesec_get_property(void);
extern void filesec_init(void);
extern void filesec_set_property(void);
extern void fremovexattr(void);
extern void fsctl(void);
extern void fsetattrlist(void);
extern void fsetxattr(void);
extern void fstat(void);
extern void fstatat(void);
extern void fstatfs(void);
extern void fstatx_np(void);
extern void fsync(void);
extern void fts_close(void);
extern void fts_open(void);
extern void fts_read(void);
extern void getattrlistat(void);
extern void getattrlistbulk(void);
extern void getegid(void);
extern void geteuid(void);
extern void getgid(void);
extern void getpwnam_r(void);
extern void getpwuid_r(void);
extern void getuid(void);
extern void lchflags(void);
extern void lchmod(void);
extern void lstat(void);
extern void mkdir(void);
extern void mkdirat(void);
extern void mkdtemp(void);
extern void mkpath_np(void);
extern void mkstemp(void);
extern void notify_cancel(void);
extern void notify_check(void);
extern void notify_get_state(void);
extern void notify_post(void);
extern void notify_register_check(void);
extern void notify_register_dispatch(void);
extern void notify_set_state(void);
extern void open(void);
extern void open_dprotected_np(void);
extern void openat(void);
extern void openat_dprotected_np(void);
extern void opendir(void);
extern void pread(void);
extern void read(void);
extern void readdir(void);
extern void readlink(void);
extern void removefile(void);
extern void removefile_state_alloc(void);
extern void removefile_state_free(void);
extern void removefile_state_get(void);
extern void removefile_state_set(void);
extern void removexattr(void);
extern void rename(void);
extern void renamex_np(void);
extern void sandbox_check_protected_app_container(void);
extern void sandbox_container_path_for_audit_token(void);
extern void sandbox_container_path_for_pid(void);
extern void sandbox_extension_consume(void);
extern void sandbox_extension_issue_file(void);
extern void sandbox_extension_issue_file_to_process(void);
extern void sandbox_extension_release(void);
extern void sandbox_get_container_expected(void);
extern void sandbox_register_app_container(void);
extern void sandbox_set_container_path_for_audit_token(void);
extern void setattrlistat(void);
extern void stat(void);
extern void statfs(void);
extern void symlink(void);
extern void sysconf(void);
extern void umask(void);
extern void unlink(void);
extern void write(void);
extern void writev(void);

#define EXPORT __attribute__((visibility("default")))
typedef void (*seam_fn)(void);

EXPORT const seam_fn CMCONTAINERSEAM_DEFAULT[4] = {
	container_class_supports_data_subdirectory,
	container_paths_copy_container_at,
	container_pwd_get_cached_current_user_home_path,
	container_realpath,
};
EXPORT const seam_fn CMDISPATCHSEAM_DEFAULT[6] = {
	dispatch_retain,
	dispatch_release,
	dispatch_assert_queue_not,
	dispatch_barrier_sync,
	dispatch_queue_create,
	dispatch_queue_attr_make_with_autorelease_frequency,
};
EXPORT const seam_fn CMNOTIFYSEAM_DEFAULT[7] = {
	notify_cancel,
	notify_check,
	notify_post,
	notify_register_check,
	notify_register_dispatch,
	notify_get_state,
	notify_set_state,
};
EXPORT const seam_fn CMPWDSEAM_DEFAULT[7] = {
	geteuid,
	getegid,
	getgid,
	getpwnam_r,
	getpwuid_r,
	getuid,
	sysconf,
};
EXPORT const seam_fn CMQUARANTINESEAM_DEFAULT[11] = {
	_qtn_error,
	_qtn_file_alloc,
	_qtn_file_free,
	_qtn_file_get_flags,
	_qtn_file_set_flags,
	_qtn_file_init,
	_qtn_file_init_with_path,
	_qtn_file_apply_to_path,
	_qtn_file_set_identifier,
	_qtn_file_set_metadata,
	_qtn_file_set_timestamp,
};
EXPORT const seam_fn CMSANDBOXSEAM_DEFAULT[10] = {
	sandbox_check_protected_app_container,
	sandbox_container_path_for_pid,
	sandbox_container_path_for_audit_token,
	sandbox_extension_consume,
	sandbox_extension_issue_file,
	sandbox_extension_issue_file_to_process,
	sandbox_extension_release,
	sandbox_get_container_expected,
	sandbox_register_app_container,
	sandbox_set_container_path_for_audit_token,
};
EXPORT const seam_fn CMFSSEAM_DEFAULT[90] = {
	acl_add_flag_np,
	acl_add_perm,
	acl_create_entry,
	acl_delete_perm,
	acl_free,
	acl_get_entry,
	acl_get_file,
	acl_get_flagset_np,
	acl_get_permset,
	acl_get_tag_type,
	acl_init,
	acl_set_file,
	acl_set_flagset_np,
	acl_set_permset,
	acl_set_qualifier,
	acl_set_tag_type,
	acl_to_text,
	chmod,
	chown,
	close,
	closedir,
	copyfile,
	dirfd,
	dirstat_np,
	dup,
	fchflags,
	fchmod,
	fchmodx_np,
	fchown,
	fcntl,
	fdopendir,
	fflagstostr,
	fgetattrlist,
	fgetxattr,
	filesec_free,
	filesec_get_property,
	filesec_init,
	filesec_set_property,
	fremovexattr,
	fsctl,
	fsetattrlist,
	fsetxattr,
	fstat,
	fstatat,
	fstatfs,
	fstatx_np,
	fsync,
	fts_close,
	fts_open,
	fts_read,
	__getattrlist,
	getattrlistat,
	getattrlistbulk,
	lchflags,
	lchmod,
	__lchown,
	__lseek,
	lstat,
	mkdir,
	mkdirat,
	mkdtemp,
	mkpath_np,
	mkstemp,
	0,
	open,
	open_dprotected_np,
	openat,
	openat_dprotected_np,
	opendir,
	pread,
	read,
	readdir,
	readlink,
	removefile,
	removefile_state_alloc,
	removefile_state_free,
	removefile_state_get,
	removefile_state_set,
	removexattr,
	rename,
	renamex_np,
	__setattrlist,
	setattrlistat,
	stat,
	statfs,
	symlink,
	umask,
	unlink,
	write,
	writev,
};

EXPORT const seam_fn *gCMContainerSeam = CMCONTAINERSEAM_DEFAULT;
EXPORT const seam_fn *gCMDispatchSeam = CMDISPATCHSEAM_DEFAULT;
EXPORT const seam_fn *gCMFSSeam = CMFSSEAM_DEFAULT;
EXPORT const seam_fn *gCMNotifySeam = CMNOTIFYSEAM_DEFAULT;
EXPORT const seam_fn *gCMPWDSeam = CMPWDSEAM_DEFAULT;
EXPORT const seam_fn *gCMQuarantineSeam = CMQUARANTINESEAM_DEFAULT;
EXPORT const seam_fn *gCMSandboxSeam = CMSANDBOXSEAM_DEFAULT;

/*
 * container_seam_<x>_set_common(table) copies a replacement table into the
 * library's own store and uses it; container_seam_<x>_reset() goes back to
 * the default.
 */
#define SEAM(name, gvar, DEFAULT, n) \
	static seam_fn name##_store[n]; \
	EXPORT void container_seam_##name##_set_common(const seam_fn *t) \
	{ \
		for (int i = 0; i < n; i++) \
			name##_store[i] = t[i]; \
		gvar = name##_store; \
	} \
	EXPORT void container_seam_##name##_reset(void) { gvar = DEFAULT; }

SEAM(container, gCMContainerSeam, CMCONTAINERSEAM_DEFAULT, 4)
SEAM(dispatch, gCMDispatchSeam, CMDISPATCHSEAM_DEFAULT, 6)
SEAM(fs, gCMFSSeam, CMFSSEAM_DEFAULT, 90)
SEAM(notify, gCMNotifySeam, CMNOTIFYSEAM_DEFAULT, 7)
SEAM(pwd, gCMPWDSeam, CMPWDSEAM_DEFAULT, 7)
SEAM(quarantine, gCMQuarantineSeam, CMQUARANTINESEAM_DEFAULT, 11)
SEAM(sandbox, gCMSandboxSeam, CMSANDBOXSEAM_DEFAULT, 10)

/* Apple loads some file-system entry points lazily; Finch's table is static. */
EXPORT void container_seam_fs_ensure_lazy_loaded(void) {}
