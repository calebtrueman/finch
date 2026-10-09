/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* kSCNetworkInterfaceIPv4, made when the framework loads. (Its own file: the
 * SDK declares it const.) */
const void *_SCCreateIPv4Interface(void);
const void *kSCNetworkInterfaceIPv4;

__attribute__((constructor)) static void makeIPv4Interface(void)
{
	kSCNetworkInterfaceIPv4 = _SCCreateIPv4Interface();
}
