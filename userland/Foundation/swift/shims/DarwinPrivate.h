// SPDX-License-Identifier: MIT OR Apache-2.0
// What swift-foundation (FOUNDATION_FRAMEWORK) uses of the private module DarwinPrivate.
#pragma once
#import <Foundation/Foundation.h>

// sys/content_protection.h (xnu): the data protection classes.
#define PROTECTION_CLASS_DEFAULT  (-1)
#define PROTECTION_CLASS_DIR_NONE 0
#define PROTECTION_CLASS_A 1
#define PROTECTION_CLASS_B 2
#define PROTECTION_CLASS_C 3
#define PROTECTION_CLASS_D 4
#define PROTECTION_CLASS_E 5
#define PROTECTION_CLASS_F 6

// dirhelper (Libc's private dirhelper.h): per-user directories.
#include <sys/types.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef enum {
    DIRHELPER_RELATIVE_TRASH = 2,
} dirhelper_which_t;
/// The trash for `path`'s volume: ~/.Trash for the home directory, and
/// <volume>/.Trashes/<uid> otherwise, as Apple's dirhelper answers.
static inline char * _Nullable __user_relative_dirname(uid_t uid, dirhelper_which_t which,
    const char * _Nonnull path, char * _Nonnull buf, size_t len) {
    if (which != DIRHELPER_RELATIVE_TRASH) return NULL;
    int n = strcmp(path, "/") == 0 ? snprintf(buf, len, "/.Trashes/%u", (unsigned)uid)
                                   : snprintf(buf, len, "%s/.Trash", path);
    return n > 0 && (size_t)n < len ? buf : NULL;
}

// sysdir (Libc's private sysdir.h): the search path domains, with the
// private ones; Finch knows only the public ones.
#include <sysdir.h>
typedef enum __attribute__((flag_enum, enum_extensibility(open))) : unsigned int {
    SYSDIR_DOMAIN_MASK_PRIVATE_NONE = 0,
} sysdir_search_path_domain_private_mask_t;
static inline sysdir_search_path_enumeration_state sysdir_start_search_path_enumeration_private(
    sysdir_search_path_directory_t dir, sysdir_search_path_domain_private_mask_t domainMask) {
    return sysdir_start_search_path_enumeration(dir, (sysdir_search_path_domain_mask_t)(domainMask & SYSDIR_DOMAIN_MASK_ALL));
}
