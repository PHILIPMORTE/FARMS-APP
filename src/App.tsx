import { Navigate, Route, Routes } from 'react-router-dom'
import { Toaster } from 'sonner'
import { AuthProvider } from '@/context/AuthContext'
import { NotificationsProvider } from '@/context/NotificationsContext'
import { AppShell } from '@/components/AppShell'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { ErrorBoundary } from '@/components/ErrorBoundary'

import Landing from '@/pages/Landing'
import LoginPage from '@/pages/auth/LoginPage'
import AuthCallback from '@/pages/auth/AuthCallback'
import NotificationsPage from '@/pages/NotificationsPage'

import OwnerDashboard from '@/pages/owner/Dashboard'
import OwnerCalendar from '@/pages/owner/Calendar'
import OwnerMarket from '@/pages/owner/Market'
import OwnerFinance from '@/pages/owner/Finance'
import OwnerJobs from '@/pages/owner/Jobs'
import OwnerAccount from '@/pages/owner/Account'

import FarmerJobs from '@/pages/farmer/Jobs'
import FarmerApplications from '@/pages/farmer/Applications'
import FarmerAccount from '@/pages/farmer/Account'

import BuyerMarket from '@/pages/buyer/Market'
import BuyerOrders from '@/pages/buyer/Orders'
import BuyerAccount from '@/pages/buyer/Account'

export default function App() {
  return (
    <ErrorBoundary>
    <AuthProvider>
      <NotificationsProvider>
      <Routes>
        <Route path="/" element={<Landing />} />

        <Route path="/owner/login" element={<LoginPage role="owner" />} />
        <Route path="/farmer/login" element={<LoginPage role="farmer" />} />
        <Route path="/buyer/login" element={<LoginPage role="buyer" />} />
        <Route path="/auth/callback" element={<AuthCallback />} />

        {/* Farm Owner */}
        <Route
          path="/owner"
          element={
            <ProtectedRoute role="owner">
              <AppShell role="owner" />
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/owner/dashboard" replace />} />
          <Route path="dashboard" element={<OwnerDashboard />} />
          <Route path="calendar" element={<OwnerCalendar />} />
          <Route path="market" element={<OwnerMarket />} />
          <Route path="finance" element={<OwnerFinance />} />
          <Route path="jobs" element={<OwnerJobs />} />
          <Route path="account" element={<OwnerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        {/* Farmer */}
        <Route
          path="/farmer"
          element={
            <ProtectedRoute role="farmer">
              <AppShell role="farmer" />
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/farmer/jobs" replace />} />
          <Route path="jobs" element={<FarmerJobs />} />
          <Route path="applications" element={<FarmerApplications />} />
          <Route path="account" element={<FarmerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        {/* Buyer */}
        <Route
          path="/buyer"
          element={
            <ProtectedRoute role="buyer">
              <AppShell role="buyer" />
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/buyer/market" replace />} />
          <Route path="market" element={<BuyerMarket />} />
          <Route path="orders" element={<BuyerOrders />} />
          <Route path="account" element={<BuyerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>

      <Toaster position="top-center" richColors closeButton />
      </NotificationsProvider>
    </AuthProvider>
    </ErrorBoundary>
  )
}
