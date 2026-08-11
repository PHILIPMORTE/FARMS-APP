export type Role = 'owner' | 'farmer' | 'buyer'
export type Crop = 'rice' | 'corn' | 'watermelon'
export type JobCrop = Crop | 'general'
export type JobType = 'seasonal' | 'part-time' | 'full-time'
export type JobStatus = 'open' | 'closed' | 'filled'
export type AppStatus = 'pending' | 'accepted' | 'rejected'
export type Availability = 'available' | 'busy' | 'unavailable'
export type ProductStatus = 'available' | 'reserved' | 'sold'
export type OrderStatus = 'completed' | 'pending' | 'cancelled'
export type TxnType = 'income' | 'expense'
export type NotifType =
  | 'harvest' | 'sale' | 'purchase' | 'job_post'
  | 'application' | 'hired' | 'rejected' | 'general'

export interface Profile {
  id: string
  user_id: string
  role: Role
  name: string
  phone: string
  email: string | null
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
  applied_at: string
  updated_at: string
  job_posts?: JobPost | null
  profiles?: Profile | null
  farmer_profiles?: FarmerProfile | null
}

export interface Schedule {
  id: string
  farm_id: string
  crop: Crop
  planting_month: string
  estimated_months: number
  created_at: string
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
  quantity: number
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
  created_at: string
}

export interface Order {
  id: string
  buyer_id: string
  product_id: string
  quantity: number
  total_price: number
  status: OrderStatus
  created_at: string
  products?: Product | null
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
