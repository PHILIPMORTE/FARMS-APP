import { Component } from 'react'
import type { ErrorInfo, ReactNode } from 'react'

interface Props {
  children: ReactNode
}
interface State {
  error: Error | null
}

/**
 * Without this, any render error blanks the whole app with no explanation —
 * you get a white screen and have to open the browser console to learn
 * anything. This catches the crash, keeps the rest of the app alive, and
 * shows what actually went wrong.
 */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('FARMS crashed while rendering:', error, info.componentStack)
  }

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="flex min-h-screen items-center justify-center bg-soil-50 px-5 py-10">
        <div className="card w-full max-w-lg p-6">
          <span className="text-3xl" aria-hidden>
            ⚠️
          </span>
          <h1 className="mt-3 text-[20px] font-bold">This page could not load</h1>
          <p className="mt-1.5 text-[14px] leading-relaxed text-soil-600">
            Something went wrong while drawing this screen. The details below say what.
          </p>

          <pre className="mt-4 max-h-52 overflow-auto whitespace-pre-wrap rounded-lg bg-soil-100 p-3.5 text-[12px] leading-relaxed text-soil-800">
            {error.message}
          </pre>

          <div className="mt-5 grid grid-cols-2 gap-2">
            <button className="btn-ghost" onClick={() => this.setState({ error: null })}>
              Try again
            </button>
            <button className="btn-primary" onClick={() => (window.location.href = '/')}>
              Back to start
            </button>
          </div>
        </div>
      </div>
    )
  }
}
