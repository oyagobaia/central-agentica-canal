#!/usr/bin/env bash
# chave-de-leitura.sh: liga a VPS do cliente ao repositório PRIVADO do produto por uma chave SSH só de leitura
# (opção B, 10/11/2026). Cada cliente tem a própria chave; o MPV revoga uma sem tocar nas outras.
#
#   sudo bash chave-de-leitura.sh gerar             cria a chave e mostra a parte pública para mandar ao MPV
#   sudo bash chave-de-leitura.sh testar            confere se o MPV já liberou (lê o repositório sem baixar nada)
#   sudo bash chave-de-leitura.sh clonar <pasta>    baixa o código por SSH, já ligado à chave (o atualizar usa sozinho)
#   sudo bash chave-de-leitura.sh ligar <pasta>     passa um clone que já existe para SSH com a chave
#
# A chave do GitHub não é aceita no primeiro contato: o script lê as chaves oficiais em https://api.github.com/meta
# (HTTPS, certificado conferido) e só fala com o servidor que apresentar uma delas.
#
# Ambiente: YB_CHAVE_DIR (padrão /etc/ybcentral/deploy), YB_REPO_CODIGO (padrão oyagobaia/ybcentral),
#           YB_GITHUB_META (padrão https://api.github.com/meta, só para teste).
set -euo pipefail

DIR="${YB_CHAVE_DIR:-/etc/ybcentral/deploy}"
REPO="${YB_REPO_CODIGO:-oyagobaia/ybcentral}"
META="${YB_GITHUB_META:-https://api.github.com/meta}"
CHAVE="$DIR/id_ed25519"
CONHECIDOS="$DIR/known_hosts"
URL="git@github.com:$REPO.git"

falha() { printf 'chave-de-leitura: %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '  o que fazer: %s\n' "$2" >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || falha "YB_REPO_CODIGO inválido: $REPO" "use dono/repositorio"
ssh_cmd() { printf 'ssh -i %q -o IdentitiesOnly=yes -o UserKnownHostsFile=%q -o StrictHostKeyChecking=yes -o BatchMode=yes' "$CHAVE" "$CONHECIDOS"; }

gravar_chaves_do_github() {
    command -v curl >/dev/null || falha "falta o curl" "apt install curl"
    command -v node >/dev/null || falha "falta o node" "instale o node antes (o produto roda nele)"
    local tmp; tmp="$(mktemp "$DIR/.known_hosts.XXXXXX")"
    curl -fsS --max-time 20 "$META" | node -e '
        let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
          const k = (JSON.parse(s).ssh_keys || []).filter((x) => /^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+\/=]+$/.test(x));
          if (!k.length) { console.error("a API do GitHub não trouxe ssh_keys"); process.exit(1); }
          process.stdout.write(k.map((x) => `github.com ${x}\n`).join(""));
        });' >"$tmp" || { mv -f "$tmp" "$tmp.falhou"; falha "não consegui ler as chaves oficiais do GitHub em $META" "confira a internet da VPS e rode de novo"; }
    chmod 600 "$tmp"; mv -f "$tmp" "$CONHECIDOS"
}

case "${1:-}" in
    gerar)
        command -v ssh-keygen >/dev/null || falha "falta o ssh-keygen" "apt install openssh-client"
        install -d -m 700 "$DIR"
        if [ -e "$CHAVE" ]; then
            echo "A chave já existe em $CHAVE; não troquei (trocar exige revogar a antiga no MPV)."
        else
            ssh-keygen -q -t ed25519 -N "" -C "central-agentica-$(hostname -s 2>/dev/null || echo vps)" -f "$CHAVE"
            chmod 600 "$CHAVE"; chmod 644 "$CHAVE.pub"
        fi
        gravar_chaves_do_github
        echo; echo "Mande esta linha para o MPV (é a parte pública; a privada nunca sai desta máquina):"; echo
        cat "$CHAVE.pub"; echo
        echo "Depois que o MPV liberar: sudo bash $0 testar"
        ;;
    testar)
        [ -e "$CHAVE" ] || falha "não há chave em $CHAVE" "rode: sudo bash $0 gerar"
        [ -e "$CONHECIDOS" ] || gravar_chaves_do_github
        if GIT_SSH_COMMAND="$(ssh_cmd)" GIT_TERMINAL_PROMPT=0 git ls-remote "$URL" HEAD >/dev/null 2>"$DIR/.ultimo-teste.err"; then
            echo "ok: esta VPS lê $REPO com a chave de leitura."
        else
            falha "o GitHub recusou a chave ($(grep -m1 -iE "denied|not found|error|fatal" "$DIR/.ultimo-teste.err" || tail -1 "$DIR/.ultimo-teste.err"))" "confira se o MPV já cadastrou a chave pública; se acabou de cadastrar, espere um minuto e teste de novo"
        fi
        ;;
    clonar)
        destino="${2:-}"; [ -n "$destino" ] || falha "diga a pasta: sudo bash $0 clonar /root/central-agentica"
        [ ! -e "$destino" ] || falha "$destino já existe; não mexi" "escolha outra pasta ou use: sudo bash $0 ligar $destino"
        bash "$0" testar >/dev/null
        GIT_SSH_COMMAND="$(ssh_cmd)" GIT_TERMINAL_PROMPT=0 git clone -q "$URL" "$destino"
        git -C "$destino" config core.sshCommand "$(ssh_cmd)"
        echo "ok: código em $destino, ligado à chave de leitura. Próximo passo: cd $destino && sudo ./install.sh"
        ;;
    ligar)
        destino="${2:-}"; [ -d "$destino/.git" ] || falha "$destino não é um clone git" "passe a pasta do clone que o instalador anotou"
        bash "$0" testar >/dev/null
        git -C "$destino" remote set-url origin "$URL"
        git -C "$destino" config core.sshCommand "$(ssh_cmd)"
        GIT_TERMINAL_PROMPT=0 git -C "$destino" fetch -q origin
        echo "ok: $destino agora atualiza por SSH com a chave de leitura."
        ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
