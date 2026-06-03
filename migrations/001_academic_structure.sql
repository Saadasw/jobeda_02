-- Migration 001: Academic Structure
-- Creates tables for academic years, classes, and sections

CREATE TABLE IF NOT EXISTS academic_years (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    is_current BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW(),
    created_by TEXT NULL,
    updated_at TIMESTAMP NULL,
    updated_by TEXT NULL
);

CREATE TABLE IF NOT EXISTS classes (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    created_by TEXT NULL,
    updated_at TIMESTAMP NULL,
    updated_by TEXT NULL
);

CREATE TABLE IF NOT EXISTS sections (
    id SERIAL PRIMARY KEY,
    class_id INT NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    created_by TEXT NULL,
    updated_at TIMESTAMP NULL,
    updated_by TEXT NULL
);
