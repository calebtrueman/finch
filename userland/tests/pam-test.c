/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-pam-test <service> [user]: pam_start() a service and report the
 * result and errno (OpenPAM sets it to the underlying cause), then pam_end().
 */
#include <errno.h>
#include <security/pam_appl.h>
#include <stdio.h>
#include <string.h>

static int conv(int n, const struct pam_message **m, struct pam_response **r, void *d)
{
	(void)n; (void)m; (void)r; (void)d;
	return PAM_CONV_ERR;
}

int
main(int argc, char **argv)
{
	struct pam_conv c = { conv, NULL };
	pam_handle_t *h = NULL;
	errno = 0;
	int r = pam_start(argc > 1 ? argv[1] : "su", argc > 2 ? argv[2] : "root", &c, &h);
	int e = errno;
	printf("pam_start(%s): %d (%s), errno %d (%s)\n", argc > 1 ? argv[1] : "su", r,
	    pam_strerror(h, r), e, strerror(e));
	if (h) pam_end(h, r);
	return r != PAM_SUCCESS;
}
