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
import AdminLoginPage from '@/pages/auth/AdminLoginPage'
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
import FarmerLogs from '@/pages/farmer/Logs'
import FarmerHistory from '@/pages/farmer/History'

import OwnerOrders from '@/pages/owner/Orders'
import OwnerAttendance from '@/pages/owner/Attendance'
import { VerificationGate } from '@/components/VerificationGate'
import { PrivacyGate } from '@/components/PrivacyGate'
import { AdminDashboard, AdminVerifications } from '@/pages/admin/Dashboard'
import { AdminUsers, AdminCatalog, AdminOrders } from '@/pages/admin/Manage'
import { AdminRequests, RequestAdminAccess } from '@/pages/admin/Requests'

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
        <Route path="/admin/login" element={<AdminLoginPage />} />
        <Route path="/admin/request" element={<RequestAdminAccess />} />
        <Route path="/auth/callback" element={<AuthCallback />} />

        <Route
          path="/owner"
          element={
            <ProtectedRoute role="owner">
              <PrivacyGate>
                <VerificationGate role="owner">
                  <AppShell role="owner" />
                </VerificationGate>
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/owner/dashboard" replace />} />
          <Route path="dashboard" element={<OwnerDashboard />} />
          <Route path="calendar" element={<OwnerCalendar />} />
          <Route path="market" element={<OwnerMarket />} />
          <Route path="finance" element={<OwnerFinance />} />
          <Route path="jobs" element={<OwnerJobs />} />
          <Route path="attendance" element={<OwnerAttendance />} />
          <Route path="orders" element={<OwnerOrders />} />
          <Route path="account" element={<OwnerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route
          path="/farmer"
          element={
            <ProtectedRoute role="farmer">
              <PrivacyGate>
                <VerificationGate role="farmer">
                  <AppShell role="farmer" />
                </VerificationGate>
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/farmer/jobs" replace />} />
          <Route path="jobs" element={<FarmerJobs />} />
          <Route path="applications" element={<FarmerApplications />} />
          <Route path="logs" element={<FarmerLogs />} />
          <Route path="history" element={<FarmerHistory />} />
          <Route path="account" element={<FarmerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route
          path="/buyer"
          element={
            <ProtectedRoute role="buyer">
              <PrivacyGate>
                <VerificationGate role="buyer">
                  <AppShell role="buyer" />
                </VerificationGate>
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/buyer/market" replace />} />
          <Route path="market" element={<BuyerMarket />} />
          <Route path="orders" element={<BuyerOrders />} />
          <Route path="account" element={<BuyerAccount />} />
          <Route path="notifications" element={<NotificationsPage />} />
        </Route>

        <Route
          path="/admin"
          element={
            <ProtectedRoute role="admin">
              <PrivacyGate>
                <AppShell role="admin" />
              </PrivacyGate>
            </ProtectedRoute>
          }
        >
          <Route index element={<Navigate to="/admin/dashboard" replace />} />
          <Route path="dashboard" element={<AdminDashboard />} />
          <Route path="verifications" element={<AdminVerifications />} />
          <Route path="users" element={<AdminUsers />} />
          <Route path="requests" element={<AdminRequests />} />
          <Route path="catalog" element={<AdminCatalog />} />
          <Route path="orders" element={<AdminOrders />} />
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
