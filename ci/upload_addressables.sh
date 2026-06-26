#!/usr/bin/env bash
# ci/upload_addressables.sh
# Subir Addressables a Cloudflare R2 (S3 compatible)
# Requisitos: aws cli v2 instalado en el runner o en tu máquina local;
# secrets en GitHub: R2_ACCESS_KEY, R2_SECRET_KEY, R2_ACCOUNT_ID, R2_BUCKET
set -euo pipefail

# ---------- Config ----------
BUILD_TARGET="${1:-Android}"
PROJECT_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_DIR="${PROJECT_ROOT}/ServerData/${BUILD_TARGET}"
LIB_AA_DIR="${PROJECT_ROOT}/Library/com.unity.addressables/aa"
LOG_DIR="${PROJECT_ROOT}/ci/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="${LOG_DIR}/upload_addressables_${BUILD_TARGET}_${TIMESTAMP}.log"

echo "==== Upload Addressables started: ${TIMESTAMP} ====" | tee -a "${LOG_FILE}"
echo "Project root: ${PROJECT_ROOT}" | tee -a "${LOG_FILE}"
echo "Build target: ${BUILD_TARGET}" | tee -a "${LOG_FILE}"

# ---------- localizar catalog.json ----------
CATALOG_SRC="$(find "${BUILD_DIR}" -maxdepth 4 -type f -name "catalog.json" 2>/dev/null | head -n 1 || true)"
# Si preferís buscar en Library en vez de ServerData, descomenta la línea siguiente y comenta la anterior:
# CATALOG_SRC="$(find "${LIB_AA_DIR}" -maxdepth 4 -type f -name "catalog.json" 2>/dev/null | head -n 1 || true)"

if [[ -z "${CATALOG_SRC}" ]]; then
  echo "ERROR: catalog.json no encontrado en ${BUILD_DIR}. Asegurate de haber copiado el catálogo y los bundles a ServerData/${BUILD_TARGET}." | tee -a "${LOG_FILE}"
  exit 1
fi
HASH_SRC="$(dirname "${CATALOG_SRC}")/catalog.hash"
echo "Catalog found at: ${CATALOG_SRC}" | tee -a "${LOG_FILE}"

# ---------- validaciones ----------
if [[ ! -d "${BUILD_DIR}" ]]; then
  echo "ERROR: Build dir ${BUILD_DIR} no existe o está vacío." | tee -a "${LOG_FILE}"
  exit 1
fi

if [[ -z "${R2_ACCESS_KEY:-}" || -z "${R2_SECRET_KEY:-}" || -z "${R2_ACCOUNT_ID:-}" || -z "${R2_BUCKET:-}" ]]; then
  echo "ERROR: Variables R2_ACCESS_KEY, R2_SECRET_KEY, R2_ACCOUNT_ID, R2_BUCKET deben estar definidas." | tee -a "${LOG_FILE}"
  exit 1
fi

# ---------- configurar AWS env ----------
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_KEY}"
export AWS_DEFAULT_REGION="us-east-1"

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
BUCKET_PATH="s3://${R2_BUCKET}/Addressables/${BUILD_TARGET}"

echo "Endpoint: ${ENDPOINT}" | tee -a "${LOG_FILE}"
echo "Bucket path: ${BUCKET_PATH}" | tee -a "${LOG_FILE}"

# ---------- copiar catalog y hash al build dir si vienen desde Library ----------
# (si ya dejaste todo en ServerData no hace falta)
if [[ "${CATALOG_SRC}" != "${BUILD_DIR}/catalog.json" ]]; then
  mkdir -p "${BUILD_DIR}"
  cp -f "${CATALOG_SRC}" "${BUILD_DIR}/catalog.json"
  if [[ -f "${HASH_SRC}" ]]; then cp -f "${HASH_SRC}" "${BUILD_DIR}/catalog.hash"; fi
  echo "Catalogo copiado a ${BUILD_DIR}" | tee -a "${LOG_FILE}"
fi

# ---------- subir con retries ----------
MAX_RETRIES=3
RETRY_DELAY=5

upload_once() {
  aws s3 cp "${BUILD_DIR}" "${BUCKET_PATH}" \
    --recursive \
    --endpoint-url "${ENDPOINT}" \
    --cache-control "public, max-age=31536000, immutable" \
    --only-show-errors
}

attempt=0
while [[ ${attempt} -lt ${MAX_RETRIES} ]]; do
  attempt=$((attempt+1))
  echo "Upload attempt ${attempt}/${MAX_RETRIES}..." | tee -a "${LOG_FILE}"
  if upload_once 2>&1 | tee -a "${LOG_FILE}"; then
    echo "Upload exitoso en intento ${attempt}" | tee -a "${LOG_FILE}"
    break
  else
    echo "Upload falló en intento ${attempt}" | tee -a "${LOG_FILE}"
    if [[ ${attempt} -lt ${MAX_RETRIES} ]]; then
      echo "Reintentando en ${RETRY_DELAY}s..." | tee -a "${LOG_FILE}"
      sleep "${RETRY_DELAY}"
    else
      echo "ERROR: Upload falló después de ${MAX_RETRIES} intentos." | tee -a "${LOG_FILE}"
      exit 1
    fi
  fi
done

# ---------- verificación ----------
CATALOG_URL="${ENDPOINT}/${R2_BUCKET}/Addressables/${BUILD_TARGET}/catalog.json"
echo "Verificando accesibilidad de ${CATALOG_URL}" | tee -a "${LOG_FILE}"

if curl -I -s -f "${CATALOG_URL}" >/dev/null 2>&1; then
  echo "Catalog accessible via HTTP (public)." | tee -a "${LOG_FILE}"
else
  echo "Catalog no accesible públicamente. Generando presigned URL para verificación..." | tee -a "${LOG_FILE}"
  PRESIGNED_URL="$(aws s3 presign "s3://${R2_BUCKET}/Addressables/${BUILD_TARGET}/catalog.json" --endpoint-url "${ENDPOINT}" --expires-in 3600 2>/dev/null || true)"
  if [[ -n "${PRESIGNED_URL}" ]]; then
    echo "Presigned URL generated. Testing download (HEAD)..." | tee -a "${LOG_FILE}"
    if curl -I -s -f "${PRESIGNED_URL}" >/dev/null 2>&1; then
      echo "Catalog accesible vía presigned URL." | tee -a "${LOG_FILE}"
    else
      echo "ERROR: No se pudo verificar catalog.json ni con presigned URL." | tee -a "${LOG_FILE}"
      exit 1
    fi
  else
    echo "WARNING: No se pudo generar presigned URL. Revisa permisos de la Access Key." | tee -a "${LOG_FILE}"
  fi
fi

echo "==== Upload Addressables finalizado correctamente: $(date -u +%Y%m%dT%H%M%SZ) ====" | tee -a "${LOG_FILE}"
exit 0
