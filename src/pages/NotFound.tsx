import { Link } from 'react-router-dom'
import styles from './Page.module.css'

export default function NotFound() {
  return (
    <main className={styles.page}>
      <section className={styles.panel} aria-labelledby="not-found-title">
        <p className={styles.eyebrow}>Erro 404</p>
        <h1 id="not-found-title">Página não encontrada</h1>
        <p className={styles.description}>Este endereço não existe.</p>
        <Link className={styles.link} to="/">Voltar ao início</Link>
      </section>
    </main>
  )
}
