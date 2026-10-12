import { useEffect, useState } from 'react'
import { invoke, isTauri } from '@tauri-apps/api/core'
import styles from './Page.module.css'

type LocalServiceStatus = 'starting' | 'ready' | 'unavailable' | 'web'

const statusMessage: Record<LocalServiceStatus, string> = {
  starting: 'Iniciando os serviços locais...',
  ready: 'Sistema local pronto.',
  unavailable: 'Não foi possível iniciar os serviços locais.',
  web: 'Modo web: serviços locais não iniciados.',
}

export default function Home() {
  const runningInTauri = isTauri()
  const [serviceStatus, setServiceStatus] = useState<LocalServiceStatus>(
    runningInTauri ? 'starting' : 'web',
  )

  useEffect(() => {
    if (!runningInTauri) return

    let active = true
    const refreshStatus = async () => {
      try {
        const status = await invoke<string>('desktop_status')
        if (active) {
          setServiceStatus(
            status === 'ready' ? 'ready' : status === 'starting' ? 'starting' : 'unavailable',
          )
        }
      } catch {
        if (active) setServiceStatus('unavailable')
      }
    }

    void refreshStatus()
    const interval = window.setInterval(() => void refreshStatus(), 1_000)
    return () => {
      active = false
      window.clearInterval(interval)
    }
  }, [runningInTauri])

  return (
    <main className={styles.page}>
      <section className={styles.panel} aria-labelledby="home-title">
        <p className={styles.eyebrow}>Ambiente local</p>
        <h1 id="home-title">Carbon Control</h1>
        <p className={styles.description}>App Controle Financeiro · Fundação técnica</p>
        <p className={styles.status} role="status" aria-live="polite">
          <span
            className={`${styles.dot} ${styles[`dot-${serviceStatus}`]}`}
            aria-hidden="true"
          />
          {statusMessage[serviceStatus]}
        </p>
      </section>
    </main>
  )
}
