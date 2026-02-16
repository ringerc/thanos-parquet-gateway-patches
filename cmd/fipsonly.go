//go:build fipsonly

/*
 * When this file is included in the build with the fipsonly build tag, it forces
 * the use of the FIPS-only crypto package. This will force FIPS at build time,
 * resulting in a build failure if the go toolchain is not FIPS capabile. The resulting
 * binary ignores the system's FIPS mode, forcing FIPS on.
 *
 * It's also possible to build a FIPS-capable binary without forcing FIPS mode.
 * This is done by enabling GOEXPERIMENT=boringcrypto but not using the
 * fipsonly build tag.
 *
 * You can check FIPS status on the resulting binary by adding GO_LDFLAGS=-w to the
 * build, then running:
 *      go tool nm parquet-gateway | grep 'sig.BoringCrypto'
 * on the resulting binary. Non-empty output like 'crypto/internal/boring/sig.BoringCrypto.abi0'
 * indicates that the binary was built with BoringCrypto, which should be FIPS-capable.
 * It can also be worth checking for the presence of FIPS_version and FIPS_mode_set
 * symbols.
 *
 * To check if fipsonly was build, run:
 *      go tool nm parquet-gateway | grep 'sig.FIPSOnly'
 * Non-empty output like 'crypto/internal/boring/sig.FIPSOnly.abi0' indicates that FIPSOnly
 * mode is enabled. See https://pkg.go.dev/crypto/internal/boring/sig
 */

package main

import (
	_ "crypto/tls/fipsonly"
)
