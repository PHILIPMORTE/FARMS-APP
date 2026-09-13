export type Role = 'owner' | 'farmer' | 'buyer' | 'admin'
export type Crop = 'rice' | 'corn' | 'watermelon'
export type JobCrop = Crop | 'general'
export type JobType = 'seasonal' | 'part-time' | 'full-time'
export type JobStatus = 'open' | 'closed' | 'filled'
export type AppStatus = 'pending' | 'accepted' | 'rejected'
export type Availability = 'available' | 'busy' | 'unavailable'
export type ProductStatus = 'available' | 'reserved' | 'sold'
export type OrderStatus = 'completed' | 'pending' | 'cancelled'
export type OrderStage =
  | 'placed' | 'confirmed' | 'preparing' | 'ready'
  | 'shipped' | 'delivered' | 'completed' | 'cancelled'
export type VerificationStatus = 'pending' | 'approved' | 'rejected'
export type AttendanceStatus = 'present' | 'absent' | 'half_day' | 'leave'
export type TxnType = 'income' | 'expense'
export type NotifType =
  | 'harvest' | 'sale' | 'purchase' | 'job_post'
  | 'application' | 'hired' | 'rejected' | 'general'
  | 'verification' | 'order_status' | 'stock'

export interface Profile {
  id: string
  user_id: string
  role: Role
  name: string
  phone: string
  email: string | null
  avatar_url: string | null
  privacy_accepted_at: string | null
  rating_warnings: number
  restricted: boolean
  company: string | null
  address: string | null
  city: string | null
  province: string | null
  zip_code: string | null
  created_at: string
}

export interface Farm {
  id: string
  owner_id: string
  name: string
  standard_hours?: number
  latitude?: number | null
  longitude?: number | null
  address: string | null
  city: string | null
  province: string | null
  zip_code: string | null
  created_at: string
}

export interface FarmerProfile {
  id: string
  bio: string | null
  skills: string[] | null
  experience_years: number | null
  availability: Availability
  province: string | null
  city: string | null
  created_at: string
}

export interface JobPost {
  id: string
  farm_id: string
  owner_id: string
  title: string
  description: string
  crop: JobCrop
  type: JobType
  wage: number
  start_time: string
  end_time: string
  slots: number
  filled_slots: number
  location: string
  start_date: string
  end_date: string | null
  status: JobStatus
  created_at: string
  farms?: { name: string; city: string | null; province: string | null } | null
}

export interface JobApplication {
  id: string
  job_id: string
  farmer_id: string
  status: AppStatus
  message: string | null
  employment_status: string
  ended_at: string | null
  end_reason: string | null
  applied_at: string
  updated_at: string
  job_posts?: JobPost | null
  profiles?: Profile | null
  farmer_profiles?: FarmerProfile | null
}

export type ScheduleStatus = 'planned' | 'planted' | 'growing' | 'harvested' | 'cancelled'

export interface Schedule {
  id: string
  farm_id: string
  crop: Crop
  variety: string
  planting_month: string
  planting_date: string | null
  harvest_date: string | null
  estimated_months: number
  seed_kg: number
  area_ha: number | null
  field_name: string | null
  field_latitude: number | null
  field_longitude: number | null
  expected_sacks: number
  actual_sacks: number | null
  harvested_at: string | null
  status: ScheduleStatus
  note: string | null
  listed_product_id: string | null
  created_at: string
}

export interface CropProfit {
  schedule_id: string
  crop: Crop
  variety: string
  status: ScheduleStatus
  planting_date: string | null
  harvest_date: string | null
  expected_sacks: number
  actual_sacks: number | null
  expenses: number
  income: number
  estimated_value: number
}

export interface InventoryItem {
  id: string
  farm_id: string
  crop: Crop
  quantity: number
  added_at: string
}

export interface Product {
  id: string
  farm_id: string
  variety: string
  crop: Crop
  photo_url: string | null
  quantity: number
  reserved: number
  form: 'unmilled' | 'milled'
  price: number
  status: ProductStatus
  buyer_id: string | null
  created_at: string
  farms?: { name: string; city: string | null; province: string | null } | null
}

export interface Transaction {
  id: string
  farm_id: string
  type: TxnType
  category: string
  amount: number
  description: string
  date: string
  schedule_id: string | null
  crop: Crop | null
  created_at: string
}

export interface Order {
  id: string
  buyer_id: string
  product_id: string
  quantity: number
  total_price: number
  status: OrderStatus
  stage: OrderStage
  paid: boolean
  paid_at: string | null
  cancel_reason: string | null
  updated_at: string
  created_at: string
  products?: Product | null
  profiles?: Profile | null
}

export interface OrderEvent {
  id: string
  order_id: string
  stage: OrderStage
  note: string | null
  changed_by: string | null
  created_at: string
}

export interface OwnerVerification {
  id: string
  profile_id: string
  role: Role
  status: VerificationStatus
  full_name: string
  id_type: string
  id_number: string | null
  id_photo_path: string | null
  selfie_path: string | null
  latitude: number | null
  longitude: number | null
  farm_name: string
  farm_address: string
  barangay: string
  farm_size_ha: number | null
  document_url: string | null
  notes: string | null
  review_notes: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  submitted_at: string
  profiles?: Profile | null
}

export interface AttendanceRow {
  id: string
  farm_id: string
  job_id: string | null
  farmer_id: string
  work_date: string
  status: AttendanceStatus
  hours_worked: number
  daily_wage: number
  computed_pay: number
  note: string | null
  task: string
  schedule_id: string | null
  paid: boolean
  paid_at: string | null
  paid_by: string | null
  payment_status: 'unpaid' | 'pending' | 'paid'
  payment_sent_at: string | null
  payment_confirmed_at: string | null
  time_in: string | null
  time_out: string | null
  break_minutes: number
  break_started_at: string | null
  source: string
  recorded_by: string | null
  created_at: string
  profiles?: Profile | null
  job_posts?: { title: string } | null
}

export interface StockChange {
  id: string
  product_id: string | null
  farm_id: string
  changed_by: string | null
  old_quantity: number
  new_quantity: number
  reason: string
  source: string
  created_at: string
  products?: { variety: string } | null
  profiles?: Profile | null
}

export interface Notification {
  id: string
  user_id: string
  message: string
  type: NotifType
  link: string
  unread: boolean
  created_at: string
}
