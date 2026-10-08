/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Included before IOKitUser's pwr_mgt.subproj/IOPMEnergyPrefs.c
 * (userland/IOKit/build.sh). The file sends powerd these XPC message keys,
 * which no published header defines. They only travel between IOKit and
 * the power daemon, which Finch provides too, so Finch names them.
 */
#ifndef FINCH_IOPM_ENERGY_PREFS_H
#define FINCH_IOPM_ENERGY_PREFS_H

#define kEnergyModeKey        "EnergyMode"
#define kPowerSourceKey       "PowerSource"
#define kGamingEnergyModeKey  "GamingEnergyMode"

#endif
