import styles from './Page.module.css'

export default function Home() {
  return (
    <main className={styles.page}>
      <section className={styles.panel} aria-labelledby="home-title">
        <p className={styles.eyebrow}>Ambiente local</p>
        <h1 id="home-title">Carbon Control</h1>
        <p className={styles.description}>App Controle Financeiro · Fase 0</p>
        <p className={styles.status}>
          <span className={styles.dot} aria-hidden="true" />
          Frontend iniciado corretamente
        </p>
      </section>
    </main>
  )
}
