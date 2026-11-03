//go:build tools

// De tools voor pki/pki.test.sh, gebouwd door .github/scripts/install-pki-tools.sh. Door ze hier te
// importeren zijn het directe dependencies in go.mod, en die werkt Dependabot wekelijks bij; een
// `tool`-regel in go.mod zou ze als `// indirect` markeren.
package tools

import (
	_ "filippo.io/age/cmd/age"
	_ "filippo.io/age/cmd/age-keygen"
	_ "github.com/cloudflare/cfssl/cmd/cfssl"
	_ "github.com/cloudflare/cfssl/cmd/cfssljson"
	_ "github.com/getsops/sops/v3/cmd/sops"
)
