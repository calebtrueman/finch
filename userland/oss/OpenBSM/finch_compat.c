/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libbsm interfaces macOS 26.4's libbsm exports that Apple's last published
 * OpenBSM (OpenBSM-21) predates. Prototypes are the SDK's <bsm/libbsm.h> and
 * <bsm/audit_session.h>; behaviour (token layouts, auditon commands, return
 * codes) was read from macOS 26.4's library. Where Apple's code has an
 * outright bug (an endless loop at EOF, a freed buffer left in the session
 * handle), this code does the safe thing instead; those places say so.
 *
 * Compiled as part of bsm_audit.c (included at its end) so au_close_with_errors
 * can share au_close's record table and helpers.
 */

#include <bsm/audit_session.h>
#include <stdio.h>
#if defined(HAVE_SYS_ENDIAN_H) && defined(HAVE_BE32ENC)
#include <sys/endian.h>
#else
#include <machine/endian.h>
#include <compat/endian.h>
#endif
#include <sys/ioctl.h>
#include <sys/filio.h>
#include <syslog.h>

/* Defined in bsm_wrappers.c. */
int audit_set_terminal_port(dev_t *p);
int audit_set_terminal_host(uint32_t *m);

/* Output flags for au_print_flags_tok() (<bsm/libbsm.h> after OpenBSM-21). */
#ifndef AU_OFLAG_RAW
#define AU_OFLAG_RAW		0x0001
#define AU_OFLAG_SHORT		0x0002
#define AU_OFLAG_XML		0x0004
#define AU_OFLAG_NORESOLVE	0x0008
#endif

/* ---- audit tokens: fields of audit_token_t ---- */

uid_t audit_token_to_auid(audit_token_t t) { return (uid_t)t.val[0]; }
uid_t audit_token_to_euid(audit_token_t t) { return (uid_t)t.val[1]; }
gid_t audit_token_to_egid(audit_token_t t) { return (gid_t)t.val[2]; }
uid_t audit_token_to_ruid(audit_token_t t) { return (uid_t)t.val[3]; }
gid_t audit_token_to_rgid(audit_token_t t) { return (gid_t)t.val[4]; }
pid_t audit_token_to_pid(audit_token_t t) { return (pid_t)t.val[5]; }
au_asid_t audit_token_to_asid(audit_token_t t) { return (au_asid_t)t.val[6]; }
int audit_token_to_pidversion(audit_token_t t) { return (int)t.val[7]; }

/* ---- auditon(2) wrappers ---- */

/* auditon(2) commands not in OpenBSM-21's headers. */
#define FINCH_A_GETSFLAGS	39
#define FINCH_A_SETSFLAGS	40
#define FINCH_A_GETCTLMODE	41
#define FINCH_A_GETEXPAFTER	43

int
audit_get_sflags(uint64_t *flags)
{
	return (auditon(FINCH_A_GETSFLAGS, flags, sizeof(*flags)));
}

int
audit_set_sflags(uint64_t flags)
{
	return (auditon(FINCH_A_SETSFLAGS, &flags, sizeof(flags)));
}

/* Not implemented on macOS either. */
int
audit_get_sflags_mask(const char *which, uint64_t *mask)
{
	(void)which;
	(void)mask;
	errno = ENOSYS;
	return (-1);
}

int
audit_set_sflags_mask(const char *which, uint64_t mask)
{
	(void)which;
	(void)mask;
	errno = ENOSYS;
	return (-1);
}

int
getacsflagsmask(const char *which, char *auditstr, size_t len)
{
	(void)which;
	(void)auditstr;
	(void)len;
	errno = ENOSYS;
	return (-1);
}

int
audit_get_ctlmode(au_ctlmode_t *mode, size_t sz)
{
	if (sz != sizeof(*mode)) {
		errno = EINVAL;
		return (-1);
	}
	return (auditon(FINCH_A_GETCTLMODE, mode, (int)sz));
}

int
audit_get_expire_after(au_expire_after_t *expire, size_t sz)
{
	if (sz != sizeof(*expire)) {
		errno = EINVAL;
		return (-1);
	}
	return (auditon(FINCH_A_GETEXPAFTER, expire, (int)sz));
}

/* ---- session flags as text ---- */

static const struct {
	uint64_t flag;
	const char *name;
} sflags_names[] = {
	{ AU_SESSION_FLAG_IS_INITIAL, "is_initial" },
	{ AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS, "has_graphic_access" },
	{ AU_SESSION_FLAG_HAS_TTY, "has_tty" },
	{ AU_SESSION_FLAG_IS_REMOTE, "is_remote" },
	{ AU_SESSION_FLAG_HAS_CONSOLE_ACCESS, "has_console_access" },
	{ AU_SESSION_FLAG_HAS_AUTHENTICATED, "has_authenticated" },
};

ssize_t
au_sflagstostr(uint64_t flags, size_t maxsize, char *buf)
{
	bool first = true;

	if (maxsize == 0)
		return (-1);
	buf[0] = '\0';
	for (size_t i = 0; i < sizeof(sflags_names) / sizeof(sflags_names[0]); i++) {
		if ((flags & sflags_names[i].flag) == 0)
			continue;
		if (!first && strlcat(buf, ",", maxsize) >= maxsize)
			return (-1);
		if (strlcat(buf, sflags_names[i].name, maxsize) >= maxsize)
			return (-1);
		first = false;
	}
	return ((ssize_t)strlen(buf));
}

int
au_strtosflags(const char *sflagsstr, uint64_t *flags)
{
	char *copy, *rest, *name;

	*flags = 0;
	if ((copy = strdup(sflagsstr)) == NULL)
		return (-1);
	rest = copy;
	while ((name = strsep(&rest, ",")) != NULL) {
		size_t i;

		for (i = 0; i < sizeof(sflags_names) / sizeof(sflags_names[0]); i++) {
			if (strcmp(name, sflags_names[i].name) == 0)
				break;
		}
		if (i == sizeof(sflags_names) / sizeof(sflags_names[0])) {
			free(copy);
			errno = EINVAL;
			return (-1);
		}
		*flags |= sflags_names[i].flag;
	}
	free(copy);
	return (0);
}

/* ---- tokens ---- */

static token_t *
finch_token(size_t len, u_char **dptr)
{
	token_t *t = malloc(sizeof(*t));

	if (t == NULL)
		return (NULL);
	if ((t->t_data = calloc(1, len)) == NULL) {
		free(t);
		return (NULL);
	}
	t->len = len;
	*dptr = t->t_data;
	return (t);
}

/*
 * A NULL-terminated array of strings: token type, 32-bit count, then each
 * string with its terminator. (<bsm/libbsm.h> still carries an older
 * (char *, int) declaration; <bsm/audit_record.h>'s char ** form is the one
 * Apple implements.)
 */
static token_t *
au_to_string_array(char **strs, u_char type)
{
	u_int32_t count = 0;
	size_t total = 0;
	u_char *dptr;
	token_t *t;

	for (char **s = strs; *s != NULL; s++) {
		total += strlen(*s) + 1;
		count++;
	}
	if ((t = finch_token(sizeof(u_char) + sizeof(u_int32_t) + total, &dptr)) == NULL)
		return (NULL);
	ADD_U_CHAR(dptr, type);
	ADD_U_INT32(dptr, count);
	for (char **s = strs; *s != NULL; s++)
		ADD_STRING(dptr, *s, strlen(*s) + 1);
	return (t);
}

token_t *
au_to_certificate_hash(char **hash)
{
	return (au_to_string_array(hash, AUT_CERT_HASH));
}

token_t *
au_to_krb5_principal(char **principal)
{
	return (au_to_string_array(principal, AUT_KRB5_PRINCIPAL));
}

/* Process identity: signer type, signing ID, team ID and code directory hash. */
token_t *
au_to_identity(uint32_t signer_type, const char *signing_id, u_char signing_id_trunc,
    const char *team_id, u_char team_id_trunc, uint8_t *cdhash, uint16_t cdhash_len)
{
	size_t sid_len = signing_id ? strlen(signing_id) : 0;
	size_t tid_len = team_id ? strlen(team_id) : 0;
	u_char *dptr;
	token_t *t;

	t = finch_token(1 + 4 + 2 + sid_len + 1 + 1 + 2 + tid_len + 1 + 1 + 2 + cdhash_len, &dptr);
	if (t == NULL)
		return (NULL);
	ADD_U_CHAR(dptr, AUT_IDENTITY);
	ADD_U_INT32(dptr, signer_type);
	ADD_U_INT16(dptr, (u_int16_t)(sid_len + 1));
	ADD_MEM(dptr, signing_id, sid_len);
	ADD_U_CHAR(dptr, '\0');
	ADD_U_CHAR(dptr, signing_id_trunc);
	ADD_U_INT16(dptr, (u_int16_t)(tid_len + 1));
	ADD_MEM(dptr, team_id, tid_len);
	ADD_U_CHAR(dptr, '\0');
	ADD_U_CHAR(dptr, team_id_trunc);
	ADD_U_INT16(dptr, cdhash_len);
	ADD_MEM(dptr, cdhash, cdhash_len);
	return (t);
}

/* macOS writes no kevent tokens either. */
struct kevent;
token_t *
au_to_kevent(struct kevent *kev)
{
	(void)kev;
	return (NULL);
}

/* ---- records ---- */

/*
 * au_close() with a distinct result for each failure: -10 bad descriptor,
 * -20 record too large, -30 - n assembling it, -40 - errno from audit(2).
 */
int
au_close_with_errors(int d, int keep, short event)
{
	au_record_t *rec;
	int retval = 0;

	rec = open_desc_table[d];
	if (rec == NULL || rec->used == 0) {
		errno = EINVAL;
		return (-10);
	}
	if (keep == AU_TO_NO_WRITE)
		goto cleanup;
	if (rec->len + MAX_AUDIT_HEADER_SIZE + AUDIT_TRAILER_SIZE > MAX_AUDIT_RECORD_SIZE) {
		fprintf(stderr, "au_close failed");
		errno = ENOMEM;
		retval = -20;
		goto cleanup;
	}
	if ((retval = au_assemble(rec, event)) < 0) {
		retval = -30 - retval;
		goto cleanup;
	}
	retval = audit(rec->data, rec->len) == 0 ? 0 : -40 - errno;
cleanup:
	au_teardown(rec);
	return (retval);
}

/* ---- au_write() wrappers with extended terminal IDs ---- */

int
audit_set_terminal_id_ex(au_tid_addr_t *tid)
{
	int ret;

	if (tid == NULL)
		return (kAUBadParamErr);
	if ((ret = audit_set_terminal_port(&tid->at_port)) != kAUNoErr)
		return (ret);
	/* As Apple's: the IPv4 host goes in at_addr[0]; at_type is left alone. */
	return (audit_set_terminal_host(&tid->at_addr[0]));
}

int
audit_write_success_ex(short event_code, token_t *misctok, au_id_t auid, uid_t euid,
    gid_t egid, uid_t ruid, gid_t rgid, pid_t pid, au_asid_t sid, au_tid_addr_t *tid)
{
	token_t *subject;

	subject = au_to_subject32_ex(auid, euid, egid, ruid, rgid, pid, sid, tid);
	if (subject == NULL) {
		syslog(LOG_ERR, "%s: au_to_subject32_ex() failed", "audit_write_success_ex()");
		return (kAUMakeSubjectTokErr);
	}
	return (audit_write(event_code, subject, misctok, 0, 0));
}

int
audit_write_failure_ex(short event_code, char *errmsg, int errret, au_id_t auid, uid_t euid,
    gid_t egid, uid_t ruid, gid_t rgid, pid_t pid, au_asid_t sid, au_tid_addr_t *tid)
{
	token_t *subject, *errtok;

	subject = au_to_subject32_ex(auid, euid, egid, ruid, rgid, pid, sid, tid);
	if (subject == NULL) {
		syslog(LOG_ERR, "%s: au_to_subject32_ex() failed", "audit_write_failure_ex()");
		return (kAUMakeSubjectTokErr);
	}
	if ((errtok = au_to_text(errmsg)) == NULL) {
		au_free_token(subject);
		syslog(LOG_ERR, "%s: au_to_text() failed", "audit_write_failure_ex()");
		return (kAUMakeTextTokErr);
	}
	return (audit_write(event_code, subject, errtok, -1, errret));
}

int
audit_write_failure_na_ex(short event_code, char *errmsg, int errret, uid_t euid, gid_t egid,
    pid_t pid, au_tid_addr_t *tid)
{
	return (audit_write_failure_ex(event_code, errmsg, errret, -1, euid, egid, -1, -1, pid,
	    -1, tid));
}

/* ---- printing ---- */

/*
 * au_print_tok() with output flags. OpenBSM-21's printers always resolve user
 * and group names, so AU_OFLAG_NORESOLVE is accepted but not honoured.
 */
void
au_print_flags_tok(FILE *outfp, tokenstr_t *tok, char *del, int oflags)
{
	char raw = (oflags & AU_OFLAG_RAW) != 0, sfrm = (oflags & AU_OFLAG_SHORT) != 0;

	if (oflags & AU_OFLAG_XML)
		au_print_tok_xml(outfp, tok, del, raw, sfrm);
	else
		au_print_tok(outfp, tok, del, raw, sfrm);
}

/* ---- the audit session device ---- */

/* <security/audit/audit_ioctl.h> */
#define FINCH_AUDITSDEV_SET_ALLSESSIONS _IOW('S', 101, int)

au_sdev_handle_t *
au_sdev_open(int flags)
{
	au_sdev_handle_t *ash;
	int on = 1;

	if ((ash = malloc(sizeof(*ash))) == NULL)
		return (NULL);
	if ((ash->ash_fp = fopen(AUDIT_SDEV_PATH, "r")) == NULL) {
		free(ash);
		return (NULL);
	}
	ash->ash_buf = NULL;
	ash->ash_reclen = 0;
	ash->ash_bytesread = 0;
	if (((flags & AU_SDEVF_ALLSESSIONS) &&
	        ioctl(fileno(ash->ash_fp), FINCH_AUDITSDEV_SET_ALLSESSIONS, &on) < 0) ||
	    ((flags & AU_SDEVF_NONBLOCK) && ioctl(fileno(ash->ash_fp), FIONBIO, &on) < 0)) {
		fclose(ash->ash_fp);
		free(ash);
		return (NULL);
	}
	return (ash);
}

int
au_sdev_close(au_sdev_handle_t *ash)
{
	int ret = fclose(ash->ash_fp);

	free(ash->ash_buf);
	free(ash);
	return (ret);
}

int
au_sdev_fd(au_sdev_handle_t *ash)
{
	return (fileno(ash->ash_fp));
}

/* Read the next whole BSM record from the device into ash_buf. */
static int
sdev_read_record(au_sdev_handle_t *ash)
{
	FILE *fp = ash->ash_fp;
	u_int32_t be_len, len;
	int c;

	/* Skip to a record header. (Apple's loops forever at EOF; this stops.) */
	for (;;) {
		c = fgetc(fp);
		if (ferror(fp))
			goto io_error;
		if (c == EOF)
			goto bad;
		if (c == AUT_HEADER32 || c == AUT_HEADER32_EX || c == AUT_HEADER64 ||
		    c == AUT_HEADER64_EX)
			break;
	}
	if (fread(&be_len, 1, sizeof(be_len), fp) < sizeof(be_len))
		goto short_read;
	len = ntohl(be_len);
	if (len <= sizeof(be_len))
		goto bad;
	if ((ash->ash_buf = calloc(1, len)) == NULL)
		goto fail;
	ash->ash_buf[0] = (u_char)c;
	be32enc(ash->ash_buf + 1, len);
	if (fread(ash->ash_buf + 5, 1, len - 5, fp) < len - 5) {
		free(ash->ash_buf);
		ash->ash_buf = NULL;   /* Apple's leaves the freed buffer in the handle */
		goto short_read;
	}
	ash->ash_reclen = (int)len;
	ash->ash_bytesread = 0;
	return (0);
short_read:
	if (ferror(fp))
		goto io_error;
bad:
	errno = EINVAL;
	goto fail;
io_error:
	clearerr(fp);
fail:
	ash->ash_reclen = -1;
	return (-1);
}

int
au_sdev_read_aia(au_sdev_handle_t *ash, int *event, auditinfo_addr_t *aia_p)
{
	*event = 0;
	memset(aia_p, 0, sizeof(*aia_p));
	if (ash->ash_buf == NULL && sdev_read_record(ash) != 0)
		return (-1);

	while (ash->ash_bytesread < ash->ash_reclen) {
		tokenstr_t tok;

		memset(&tok, 0, sizeof(tok));
		if (au_fetch_tok(&tok, ash->ash_buf + ash->ash_bytesread,
		    ash->ash_reclen - ash->ash_bytesread) != 0)
			return (-1);
		switch (tok.id) {
		case AUT_HEADER32:
			*event = tok.tt.hdr32.e_type;
			break;
		case AUT_SUBJECT32:
			aia_p->ai_auid = tok.tt.subj32.auid;
			aia_p->ai_asid = tok.tt.subj32.sid;
			aia_p->ai_termid.at_port = tok.tt.subj32.tid.port;
			aia_p->ai_termid.at_type = AU_IPv4;
			aia_p->ai_termid.at_addr[0] = tok.tt.subj32.tid.addr;
			break;
		case AUT_SUBJECT32_EX:
			aia_p->ai_auid = tok.tt.subj32_ex.auid;
			aia_p->ai_asid = tok.tt.subj32_ex.sid;
			aia_p->ai_termid.at_port = tok.tt.subj32_ex.tid.port;
			aia_p->ai_termid.at_type = tok.tt.subj32_ex.tid.type;
			memcpy(aia_p->ai_termid.at_addr, tok.tt.subj32_ex.tid.addr,
			    sizeof(aia_p->ai_termid.at_addr));
			break;
		case AUT_ARG32:
			if (tok.tt.arg32.no == 2 && strncmp("am_success", tok.tt.arg32.text, 10) == 0)
				aia_p->ai_mask.am_success = tok.tt.arg32.val;
			else if (tok.tt.arg32.no == 3 &&
			    strncmp("am_failure", tok.tt.arg32.text, 10) == 0)
				aia_p->ai_mask.am_failure = tok.tt.arg32.val;
			break;
		case AUT_ARG64:
			if (tok.tt.arg64.no == 1 && strncmp("sflags", tok.tt.arg64.text, 6) == 0)
				aia_p->ai_flags = tok.tt.arg64.val;
			break;
		case AUT_TRAILER:
			ash->ash_bytesread += (int)tok.len;
			if (ash->ash_bytesread == ash->ash_reclen) {
				free(ash->ash_buf);
				ash->ash_buf = NULL;
				ash->ash_reclen = 0;
				ash->ash_bytesread = 0;
			}
			return (0);
		}
		ash->ash_bytesread += (int)tok.len;
	}
	return (-2);
}
